// uv2800.c  (v5)
// 一加 13 关机终止电压 -> 2800mV
//
// v3 只 hook getter（读）：
//   - 无法保证 ADSP 不被别的路径写坏
//   - 卸载后 ADSP 仍保留旧值，无法恢复
//
// v5 新增：
//   1) hook setter (oplus_fg_set_deep_term_volt) —— 强制写入值 = 2800
//      => 模块加载期间，任何路径写 ADSP 都是 2800（这是"保证不变"的关键）
//   2) restore 参数（module_param）
//      restore=0（默认）: 全部强制 2800
//      restore=1        : 放行，并让 setter 写入"DT 表算出的原值"（从 target vote 回调捕获）
//      => 驱动自己的 set 调用会把 DT 原值写回 ADSP，无需模块直接调用任何内核函数
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define UV_TARGET_MV 2800

/* restore=1 时进入"恢复模式"：放行并回写 DT 原值 */
static int restore;
module_param(restore, int, 0644);
MODULE_PARM_DESC(restore, "1 = 恢复 DT 原值并停止强制");

struct uv_sig {
	const char *sym;
	unsigned int off;
	u32 want;
	int required;
	const char *desc;
};

static const struct uv_sig uv_sigs[] = {
	/* 必选：COS15/16/17 实测一致 */
	{ "oplus_comm_update_vbat_uv_thr", 0x2c, 0xb9400108, 1, "ldr w8,[x8]"   },
	{ "oplus_comm_update_vbat_uv_thr", 0x30, 0xb9000268, 1, "str w8,[x19]"  },
	{ "vbat_uv_show",                  0x10, 0xaa0203e0, 1, "mov x0,x2"     },
	{ "vbat_uv_show",                  0x20, 0x2a0803e2, 1, "mov w2,w8"     },
	/* 可选：COS16/17 一致 */
	{ "oplus_fg_get_deep_term_volt",   0x28, 0xaa0103f3, 0, "mov x19,x1"    },
	{ "oplus_fg_get_deep_term_volt",   0xd8, 0xb8696903, 0, "ldr w3,[x8,x9]" },
	{ "oplus_fg_get_deep_term_volt",   0xe0, 0xb9000263, 0, "str w3,[x19]"  },
	{ "oplus_fg_set_deep_term_volt",   0x34, 0x2a0103f3, 0, "mov w19,w1"    },
	{ "oplus_target_term_voltage_vote_callback", 0x2c, 0x2a0203f3, 0, "mov w19,w2" },
};

static struct kprobe kp_verify;

static int uv_dt_value;      /* DT 表算出的原值（从 target vote 回调捕获） */
static int uv_dt_valid;

static int uv_verify(void)
{
	int i, opt_fail = 0;

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
				pr_err("uv2800: 符号 %s 不存在 (%d) -- 拒绝加载\n", s->sym, ret);
				return ret;
			}
			pr_warn("uv2800: [可选] %s 不存在，跳过\n", s->sym);
			opt_fail = 1;
			continue;
		}
		got = *(u32 *)((u8 *)kp_verify.addr + s->off);
		unregister_kprobe(&kp_verify);
		kp_verify.addr = NULL;
		kp_verify.symbol_name = NULL;

		if (got != s->want) {
			if (s->required) {
				pr_err("uv2800: %s+%#x = %#010x，期望 %#010x -- 拒绝加载\n",
				       s->sym, s->off, got, s->want);
				return -EINVAL;
			}
			pr_warn("uv2800: [可选] %s+%#x = %#010x，期望 %#010x，跳过\n",
				s->sym, s->off, got, s->want);
			opt_fail = 1;
			continue;
		}
		pr_info("uv2800: 校验通过 %s+%#x (%s)%s\n", s->sym, s->off, s->desc,
			s->required ? "" : " [可选]");
	}
	return opt_fail ? 1 : 0;
}

/* ---- Hook 1: comm getter ---- */
static int uv_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_get = {
	.symbol_name = "oplus_comm_update_vbat_uv_thr",
	.offset = 0x30,
	.pre_handler = uv_get,
};
static int uv_get(struct kprobe *p, struct pt_regs *regs)
{
	if (!restore)
		regs->regs[8] = UV_TARGET_MV;
	return 0;
}

/* ---- Hook 2: sysfs show ---- */
static int uv_show(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_show = {
	.symbol_name = "vbat_uv_show",
	.offset = 0x20,
	.pre_handler = uv_show,
};
static int uv_show(struct kprobe *p, struct pt_regs *regs)
{
	if (!restore)
		regs->regs[8] = UV_TARGET_MV;
	return 0;
}

/* ---- Hook 3: 终止电压 getter ---- */
static int uv_term_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_get = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.offset = 0xe0,
	.pre_handler = uv_term_get,
};
static int uv_term_get(struct kprobe *p, struct pt_regs *regs)
{
	if (!restore) {
		regs->regs[3] = UV_TARGET_MV;
	} else if (uv_dt_valid) {
		/* 恢复模式：回放 DT 原值。这样投票结果与 ADSP 现值不同，
		 * 驱动自己会调用 set，再由 setter hook 写成 DT 原值 */
		regs->regs[3] = uv_dt_value;
	}
	return 0;
}

/* ---- Hook 4: 终止电压 setter —— 保证 ADSP 写入值 ---- */
static int uv_term_set(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_set = {
	.symbol_name = "oplus_fg_set_deep_term_volt",
	.offset = 0x34,
	.pre_handler = uv_term_set,
};
static int uv_term_set(struct kprobe *p, struct pt_regs *regs)
{
	if (!restore) {
		/* 正常模式：任何写入都变成 2800 */
		regs->regs[1] = UV_TARGET_MV;
	} else if (uv_dt_valid) {
		/* 恢复模式：写入 DT 原值 */
		regs->regs[1] = uv_dt_value;
		pr_info("uv2800: [恢复] 写入 DT 原值 %d mV (原请求 %d)\n",
			uv_dt_value, (int)regs->regs[1]);
	}
	return 0;
}

/* ---- Hook 5: 捕获 DT 表算出的原值 ---- */
static int uv_target_vote(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_target_vote = {
	.symbol_name = "oplus_target_term_voltage_vote_callback",
	.offset = 0,
	.pre_handler = uv_target_vote,
};
static int uv_target_vote(struct kprobe *p, struct pt_regs *regs)
{
	int v = (int)regs->regs[2];

	if (v > 2000 && v < 5000) {
		uv_dt_value = v;
		uv_dt_valid = 1;
	}
	return 0;
}

static int __init uv2800_init(void)
{
	int ret, skip;
	int n = 0;

	pr_info("uv2800: v5 init (target %d mV, restore=%d)\n", UV_TARGET_MV, restore);

	ret = uv_verify();
	if (ret < 0) {
		pr_err("uv2800: 必选校验失败，未注册任何 hook\n");
		return ret;
	}
	skip = (ret == 1);

	ret = register_kprobe(&kp_get);
	if (ret) { pr_err("uv2800: kp_get 失败 %d\n", ret); return ret; }
	n++;

	ret = register_kprobe(&kp_show);
	if (ret) { pr_err("uv2800: kp_show 失败 %d\n", ret); unregister_kprobe(&kp_get); return ret; }
	n++;

	if (!skip) {
		if (!register_kprobe(&kp_term_get)) n++;
		else pr_warn("uv2800: [可选] kp_term_get 失败\n");

		if (!register_kprobe(&kp_term_set)) n++;
		else pr_warn("uv2800: [可选] kp_term_set 失败\n");

		if (!register_kprobe(&kp_target_vote)) n++;
		else pr_warn("uv2800: [可选] kp_target_vote 失败\n");
	} else {
		pr_warn("uv2800: [可选] 跳过终止电压相关 hook（签名不匹配）\n");
	}

	pr_info("uv2800: v5 ready, %d 个 hook, %s\n", n,
		restore ? "【恢复模式】将回写 DT 原值" : "【正常模式】ADSP 写入恒为 2800mV");
	return 0;
}

static void __exit uv2800_exit(void)
{
	if (kp_target_vote.addr) unregister_kprobe(&kp_target_vote);
	if (kp_term_set.addr)    unregister_kprobe(&kp_term_set);
	if (kp_term_get.addr)    unregister_kprobe(&kp_term_get);
	if (kp_get.addr)         unregister_kprobe(&kp_get);
	if (kp_show.addr)        unregister_kprobe(&kp_show);
	pr_info("uv2800: unloaded (restore=%d)\n", restore);
}

module_init(uv2800_init);
module_exit(uv2800_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OnePlus 13: force deep term voltage to 2800mV, with DT restore mode");
