// uv2800.c  (v4)
// 一加 13 关机终止电压 -> 2800mV
//
// v3 的问题：oplus_fg_set_deep_term_volt 会把值写进 ADSP 的持久存储，
//            模块卸载后 ADSP 仍保留 2820，不会自动回到 DT 表算出的 3250。
//
// v4 的修正：卸载时自动把「DT 表算出的原值」回写一次。
//   - 在 oplus_fg_get_deep_term_volt 入口捕获 dev 指针
//   - 在 +0xe0 处先保存 x3 的原值（= DT 表算出的值），再强制成 2800
//   - 在 __exit 里先注销 hook，再调用 oplus_fg_set_deep_term_volt(dev, DT原值)
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define UV_TARGET_MV 2800

struct uv_sig {
	const char *sym;
	unsigned int off;
	u32 want;
	int required;
	const char *desc;
	int is_setter;
};

static const struct uv_sig uv_sigs[] = {
	{ "oplus_comm_update_vbat_uv_thr", 0x2c, 0xb9400108, 1, "ldr w8,[x8]"  },
	{ "oplus_comm_update_vbat_uv_thr", 0x30, 0xb9000268, 1, "str w8,[x19]" },
	{ "vbat_uv_show",                  0x10, 0xaa0203e0, 1, "mov x0,x2"    },
	{ "vbat_uv_show",                  0x20, 0x2a0803e2, 1, "mov w2,w8"    },
	{ "oplus_fg_get_deep_term_volt",   0x28, 0xaa0103f3, 0, "mov x19,x1"   },
	{ "oplus_fg_get_deep_term_volt",   0xd8, 0xb8696903, 0, "ldr w3,[x8,x9]"},
	{ "oplus_fg_get_deep_term_volt",   0xe0, 0xb9000263, 0, "str w3,[x19]" },
	{ "oplus_fg_set_deep_term_volt",   0x34, 0x2a0103f3, 0, "mov w19,w1"   , 1 },
};

static struct kprobe kp_verify;

/* 捕获到的运行期信息 */
static void *uv_dev;            /* struct device *（从 getter 入口 x0） */
static void *uv_drvdata;        /* drvdata（从 +0xe0 处 x0） */
static int   uv_dt_value;       /* DT 表算出的原值（+0xe0 处 x3 的原始值） */
static void *uv_set_addr;       /* oplus_fg_set_deep_term_volt 的地址 */
static int   uv_ready;          /* 三个关键信息是否都已捕获 */

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
		/* 顺手记下 setter 的函数地址，供卸载时回写用 */
		if (s->is_setter)
			uv_set_addr = (void *)kp_verify.addr;
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
	return opt_fail ? 1 : 0;
}

/* Hook 1: oplus_comm_update_vbat_uv_thr(mms, out) +0x30 */
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

/* Hook 2: vbat_uv_show(dev, attr, buf) +0x20 */
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

/* Hook 3a: oplus_fg_get_deep_term_volt 入口 -- 捕获 dev 指针 */
static int uv_term_entry(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_entry = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.offset = 0,
	.pre_handler = uv_term_entry,
};
static int uv_term_entry(struct kprobe *p, struct pt_regs *regs)
{
	uv_dev = (void *)regs->regs[0];
	return 0;
}

/* Hook 3b: oplus_fg_get_deep_term_volt +0xe0  -- 存原值 + 强制 2800 */
static int uv_term_pre(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.offset = 0xe0,
	.pre_handler = uv_term_pre,
};
static int uv_term_pre(struct kprobe *p, struct pt_regs *regs)
{
	uv_drvdata  = (void *)regs->regs[20];  /* 此处 x20 = drvdata（x0 已被中间的 bl 破坏）*/
	uv_dt_value = (int)regs->regs[3];      /* ★ DT 表算出的原值 */
	regs->regs[3] = UV_TARGET_MV;
	if (uv_dev && uv_set_addr && uv_dt_value > 0)
		uv_ready = 1;
	return 0;
}

/*
 * 卸载时回写 DT 原值。
 * oplus_fg_set_deep_term_volt(struct device *dev, int volt)
 * 先用 drvdata 反查校验 dev 是否有效：*((char*)dev + 8) -> x8, *((char*)x8 + 0x98) == drvdata
 */
static void uv_restore(void)
{
	int (*set_fn)(void *, int) = (int (*)(void *, int))uv_set_addr;
	void *x8;
	void *check;

	if (!uv_ready) {
		pr_warn("uv2800: 未捕获到完整信息（dev=%px set=%px dt=%d），跳过回写\n",
			uv_dev, uv_set_addr, uv_dt_value);
		return;
	}

	x8 = *(void **)((char *)uv_dev + 8);
	if (!x8) {
		pr_warn("uv2800: dev 校验失败（x8 为空），跳过回写\n");
		return;
	}
	check = *(void **)((char *)x8 + 0x98);
	if (check != uv_drvdata) {
		pr_warn("uv2800: dev 校验失败（%px != %px），跳过回写\n", check, uv_drvdata);
		return;
	}

	pr_info("uv2800: 回写 DT 原值 %d mV -> oplus_fg_set_deep_term_volt\n", uv_dt_value);
	set_fn(uv_dev, uv_dt_value);
	pr_info("uv2800: 回写完成\n");
}

static int __init uv2800_init(void)
{
	int ret, skip;
	int n = 0;

	pr_info("uv2800: v4 init (target %d mV)\n", UV_TARGET_MV);

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
		ret = register_kprobe(&kp_term_entry);
		if (ret) {
			pr_warn("uv2800: [可选] kp_term_entry 失败 %d\n", ret);
		} else {
			n++;
			ret = register_kprobe(&kp_term);
			if (ret) {
				pr_warn("uv2800: [可选] kp_term 失败 %d\n", ret);
				unregister_kprobe(&kp_term_entry);
				n--;
			} else {
				n++;
			}
		}
	} else {
		pr_warn("uv2800: [可选] 跳过 oplus_fg_get_deep_term_volt（签名不匹配）\n");
	}

	pr_info("uv2800: v4 ready, %d 个 hook, 终止电压 -> %d mV（卸载时自动回写 DT 原值）\n",
		n, UV_TARGET_MV);
	return 0;
}

static void __exit uv2800_exit(void)
{
	/* 先停掉所有强制，再回写，避免边写边被改 */
	if (kp_term.addr)
		unregister_kprobe(&kp_term);
	if (kp_term_entry.addr)
		unregister_kprobe(&kp_term_entry);
	if (kp_get.addr)
		unregister_kprobe(&kp_get);
	if (kp_show.addr)
		unregister_kprobe(&kp_show);

	uv_restore();

	pr_info("uv2800: unloaded\n");
}

module_init(uv2800_init);
module_exit(uv2800_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OnePlus 13: force deep term voltage to 2800mV, restore DT value on unload");
