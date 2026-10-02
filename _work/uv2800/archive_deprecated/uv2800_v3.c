// uv2800.c  (v3)
// 一加 13 vbat_uv / 关机终止电压 -> 2800mV
//
// v2 只改了「显示值」，实测关机仍发生在 3250mV（SOC 1%）。
// 真正的源头是 oplus_fg_get_deep_term_volt()，它从 DT 的 term_coeff 表
// 按深度放电次数查出终止电压（当前 ~1700 次 -> 3250mV）。
//
// v3 在 v2 基础上增加第三个 hook：直接改 oplus_fg_get_deep_term_volt 的输出。
//
// 设计：
//   - 只用 register_kprobe（CRC 在 6.6.30/89/118 上实测一致）
//   - 不写任何结构体字段
//   - 加载前逐条校验指令字
//       * required=1 的校验失败 -> 整个模块拒绝加载
//       * required=0 的校验失败 -> 只跳过对应的可选 hook（优雅降级）
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define UV_TARGET_MV 2800

struct uv_sig {
	const char *sym;
	unsigned int off;
	u32 want;
	int required;          /* 1=必须, 0=可选 */
	const char *desc;
};

static const struct uv_sig uv_sigs[] = {
	/* --- 必选：三版本（COS15/16/17）实测一致 --- */
	{ "oplus_comm_update_vbat_uv_thr", 0x2c, 0xb9400108, 1, "ldr w8,[x8]"  },
	{ "oplus_comm_update_vbat_uv_thr", 0x30, 0xb9000268, 1, "str w8,[x19]" },
	{ "vbat_uv_show",                  0x10, 0xaa0203e0, 1, "mov x0,x2"    },
	{ "vbat_uv_show",                  0x20, 0x2a0803e2, 1, "mov w2,w8"    },
	/* --- 可选：COS16/17 一致，COS15 不同 -> 15 上自动跳过 --- */
	{ "oplus_fg_get_deep_term_volt",   0x28, 0xaa0103f3, 0, "mov x19,x1"   },
	{ "oplus_fg_get_deep_term_volt",   0xd8, 0xb8696903, 0, "ldr w3,[x8,x9]"},
	{ "oplus_fg_get_deep_term_volt",   0xe0, 0xb9000263, 0, "str w3,[x19]" },
};

/* 用全局 kprobe 解析地址，避免在栈上构造 struct kprobe */
static struct kprobe kp_verify;

/* 逐条校验；返回 0 表示通过，负值表示必选项失败 */
static int uv_verify(void)
{
	int i;
	int opt_fail = 0;

	for (i = 0; i < ARRAY_SIZE(uv_sigs); i++) {
		const struct uv_sig *s = &uv_sigs[i];
		u32 got;
		int ret;

		kp_verify.symbol_name = s->sym;
		kp_verify.addr = NULL;
		kp_verify.offset = 0;

		ret = register_kprobe(&kp_verify);
		if (ret) {
			if (s->required) {
				pr_err("uv2800: 符号 %s 不存在 (err=%d) -- 拒绝加载\n", s->sym, ret);
				return ret;
			}
			pr_warn("uv2800: [可选] 符号 %s 不存在，跳过\n", s->sym);
			opt_fail = 1;
			continue;
		}
		got = *(u32 *)((u8 *)kp_verify.addr + s->off);
		unregister_kprobe(&kp_verify);
		kp_verify.addr = NULL;
		kp_verify.symbol_name = NULL;

		if (got != s->want) {
			if (s->required) {
				pr_err("uv2800: %s+%#x = %#010x，期望 %#010x (%s) -- 拒绝加载\n",
				       s->sym, s->off, got, s->want, s->desc);
				return -EINVAL;
			}
			pr_warn("uv2800: [可选] %s+%#x = %#010x，期望 %#010x (%s)，跳过\n",
				s->sym, s->off, got, s->want, s->desc);
			opt_fail = 1;
			continue;
		}
		pr_info("uv2800: 校验通过 %s+%#x (%s)%s\n", s->sym, s->off, s->desc,
			s->required ? "" : " [可选]");
	}
	return opt_fail ? 1 : 0;   /* 1 = 有可选 hook 被跳过 */
}

/*
 * Hook 1: oplus_comm_update_vbat_uv_thr(mms, out)  +0x30  str w8,[x19]
 *   comm-mms item 25 的唯一取值入口 -> 显示/comm 侧统一为 2800
 */
static int uv_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_get = {
	.symbol_name = "oplus_comm_update_vbat_uv_thr",
	.offset = 0x30,
	.pre_handler = uv_get,
};
static int uv_get(struct kprobe *p, struct pt_regs *regs)
{
	regs->regs[8] = UV_TARGET_MV;
	return 0;
}

/*
 * Hook 2: vbat_uv_show(dev, attr, buf)  +0x20  mov w2,w8
 *   让 sysfs 显示 2800，且不依赖 chip 结构体偏移
 */
static int uv_show(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_show = {
	.symbol_name = "vbat_uv_show",
	.offset = 0x20,
	.pre_handler = uv_show,
};
static int uv_show(struct kprobe *p, struct pt_regs *regs)
{
	regs->regs[8] = UV_TARGET_MV;
	return 0;
}

/*
 * Hook 3（可选）: oplus_fg_get_deep_term_volt(dev, out)  +0xe0  str w3,[x19]
 *   这是 3250 的真正来源：按深度放电次数查 DT term_coeff 表。
 *   把 w3 改成 2800，整条下游链（term voltage vote / shutdown voltage vote /
 *   mms_gauge_update_vbat_uv / comm set_vbat_uv_thr / push 到 ADSP）全部变 2800。
 */
static int uv_term(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.offset = 0xe0,
	.pre_handler = uv_term,
};
static int uv_term(struct kprobe *p, struct pt_regs *regs)
{
	regs->regs[3] = UV_TARGET_MV;
	return 0;
}

static int __init uv2800_init(void)
{
	int ret, skip;
	int n = 0;

	pr_info("uv2800: v3 init (target %d mV)\n", UV_TARGET_MV);

	ret = uv_verify();
	if (ret < 0) {
		pr_err("uv2800: 必选校验失败，未注册任何 hook，模块不生效\n");
		return ret;
	}
	skip = (ret == 1);

	ret = register_kprobe(&kp_get);
	if (ret) {
		pr_err("uv2800: kp_get 注册失败 %d\n", ret);
		return ret;
	}
	n++;

	ret = register_kprobe(&kp_show);
	if (ret) {
		pr_err("uv2800: kp_show 注册失败 %d\n", ret);
		unregister_kprobe(&kp_get);
		return ret;
	}
	n++;

	/* 可选 hook：只有校验通过才注册 */
	if (!skip) {
		ret = register_kprobe(&kp_term);
		if (ret)
			pr_warn("uv2800: [可选] kp_term 注册失败 %d，跳过\n", ret);
		else
			n++;
	} else {
		pr_warn("uv2800: [可选] 跳过 oplus_fg_get_deep_term_volt（本版本签名不匹配）\n");
	}

	pr_info("uv2800: v3 ready, 已注册 %d 个 hook, vbat_uv/终止电压 -> %d mV\n",
		n, UV_TARGET_MV);
	return 0;
}

static void __exit uv2800_exit(void)
{
	if (kp_get.addr)
		unregister_kprobe(&kp_get);
	if (kp_show.addr)
		unregister_kprobe(&kp_show);
	if (kp_term.addr)
		unregister_kprobe(&kp_term);
	pr_info("uv2800: unloaded\n");
}

module_init(uv2800_init);
module_exit(uv2800_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OnePlus 13: force vbat_uv / deep term voltage to 2800mV");
