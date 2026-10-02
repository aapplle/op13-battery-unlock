// uv2800.c  (v6)  —— 跨 ColorOS 15 / 16 / 17 通用
//
// v5 的问题：15 上 oplus_fg_get_deep_term_volt / oplus_fg_set_deep_term_volt
//            的偏移与 16/17 不同，导致 15 只能改显示、改不到真实关机电压。
//
// v6 的做法：把「版本差异」抽成 profile 表，模块开机时自动探测匹配哪一套。
//
//   profile          getter              setter
//   ---------------  ------------------  -----------------------------
//   ColorOS 16/17    +0xe0 str w3,[x19]  +0x34 mov w19,w1   (改 x1)
//   ColorOS 15       +0x78 str w3,[x20]  +0x58 str w9,[sp]  (改 x9)
//
// 显示相关的两个 hook（comm getter / vbat_uv_show）在 15/16/17 上完全一致。
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define UV_TARGET_MV 2800

struct uv_profile {
	const char *name;
	unsigned int get_off;
	u32 get_want;
	int get_reg;
	unsigned int set_off;
	u32 set_want;
	int set_reg;
};

static const struct uv_profile uv_profiles[] = {
	{
		.name = "ColorOS 16/17",
		.get_off = 0xe0, .get_want = 0xb9000263, .get_reg = 3,
		.set_off = 0x34, .set_want = 0x2a0103f3, .set_reg = 1,
	},
	{
		.name = "ColorOS 15",
		.get_off = 0x78, .get_want = 0xb9000283, .get_reg = 3,
		.set_off = 0x58, .set_want = 0xb90017e9, .set_reg = 9,
	},
};

/* 显示相关（三版本一致） */
struct uv_sig {
	const char *sym;
	unsigned int off;
	u32 want;
	const char *desc;
};

static const struct uv_sig uv_sigs[] = {
	{ "oplus_comm_update_vbat_uv_thr", 0x2c, 0xb9400108, "ldr w8,[x8]"  },
	{ "oplus_comm_update_vbat_uv_thr", 0x30, 0xb9000268, "str w8,[x19]" },
	{ "vbat_uv_show",                  0x10, 0xaa0203e0, "mov x0,x2"    },
	{ "vbat_uv_show",                  0x20, 0x2a0803e2, "mov w2,w8"    },
};

static struct kprobe kp_verify;

static int cur_get_reg, cur_set_reg;
static int cur_profile_idx = -1;
static const char *cur_profile = "none";

/* 用临时 kprobe 解析符号地址并读一个字 */
static int uv_read_word(const char *sym, unsigned int off, u32 *out)
{
	int ret;

	kp_verify.symbol_name = sym;
	kp_verify.addr = NULL;
	kp_verify.offset = 0;

	ret = register_kprobe(&kp_verify);
	if (ret)
		return ret;

	*out = *(u32 *)((u8 *)kp_verify.addr + off);
	unregister_kprobe(&kp_verify);
	kp_verify.addr = NULL;
	kp_verify.symbol_name = NULL;
	return 0;
}

/* 校验显示相关的 4 个点 */
static int uv_verify_display(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(uv_sigs); i++) {
		const struct uv_sig *s = &uv_sigs[i];
		u32 got;

		if (uv_read_word(s->sym, s->off, &got)) {
			pr_err("uv2800: 符号 %s 不存在 -- 拒绝加载\n", s->sym);
			return -ENOENT;
		}
		if (got != s->want) {
			pr_err("uv2800: %s+%#x = %#010x，期望 %#010x -- 拒绝加载\n",
			       s->sym, s->off, got, s->want);
			return -EINVAL;
		}
		pr_info("uv2800: 校验通过 %s+%#x (%s)\n", s->sym, s->off, s->desc);
	}
	return 0;
}

/* 探测终止电压相关的 profile */
static int uv_detect_profile(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(uv_profiles); i++) {
		const struct uv_profile *p = &uv_profiles[i];
		u32 g, s;

		if (uv_read_word("oplus_fg_get_deep_term_volt", p->get_off, &g))
			continue;
		if (uv_read_word("oplus_fg_set_deep_term_volt", p->set_off, &s))
			continue;
		if (g != p->get_want || s != p->set_want)
			continue;

		cur_get_reg = p->get_reg;
		cur_set_reg = p->set_reg;
		cur_profile_idx = i;
		cur_profile = p->name;
		pr_info("uv2800: 匹配 profile [%s]  getter+%#x setter+%#x\n",
			p->name, p->get_off, p->set_off);
		return 0;
	}
	return -ENOENT;
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
	regs->regs[8] = UV_TARGET_MV;
	return 0;
}

/* ---- Hook 3: 终止电压 getter ---- */
static int uv_term_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_get = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.pre_handler = uv_term_get,
};
static int uv_term_get(struct kprobe *p, struct pt_regs *regs)
{
	regs->regs[cur_get_reg] = UV_TARGET_MV;
	return 0;
}

/* ---- Hook 4: 终止电压 setter（保证 ADSP 写入值） ---- */
static int uv_term_set(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_set = {
	.symbol_name = "oplus_fg_set_deep_term_volt",
	.pre_handler = uv_term_set,
};
static int uv_term_set(struct kprobe *p, struct pt_regs *regs)
{
	regs->regs[cur_set_reg] = UV_TARGET_MV;
	return 0;
}

static int __init uv2800_init(void)
{
	int ret, n = 0;

	pr_info("uv2800: v6 init (target %d mV)\n", UV_TARGET_MV);

	ret = uv_verify_display();
	if (ret)
		return ret;

	ret = uv_detect_profile();
	if (ret) {
		pr_err("uv2800: 未匹配到任何 profile -- 只注册显示 hook（真实关机电压不会改变）\n");
	} else {
		kp_term_get.offset = uv_profiles[cur_profile_idx].get_off;
		kp_term_set.offset = uv_profiles[cur_profile_idx].set_off;
		if (!register_kprobe(&kp_term_get)) n++;
		else pr_warn("uv2800: kp_term_get 注册失败\n");
		if (!register_kprobe(&kp_term_set)) n++;
		else pr_warn("uv2800: kp_term_set 注册失败\n");
	}

	if (!register_kprobe(&kp_get)) n++;
	else { pr_err("uv2800: kp_get 失败\n"); return -EIO; }

	if (!register_kprobe(&kp_show)) n++;
	else { pr_err("uv2800: kp_show 失败\n"); return -EIO; }

	pr_info("uv2800: v6 ready, %d 个 hook, profile=[%s], 目标 %d mV\n",
		n, cur_profile, UV_TARGET_MV);
	return 0;
}

static void __exit uv2800_exit(void)
{
	if (kp_term_set.addr) unregister_kprobe(&kp_term_set);
	if (kp_term_get.addr) unregister_kprobe(&kp_term_get);
	if (kp_get.addr)      unregister_kprobe(&kp_get);
	if (kp_show.addr)     unregister_kprobe(&kp_show);
	pr_info("uv2800: unloaded\n");
}

module_init(uv2800_init);
module_exit(uv2800_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OnePlus 13: force deep term voltage to 2800mV (cross ColorOS 15/16/17)");
