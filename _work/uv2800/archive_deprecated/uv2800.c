// uv2800.c  (v2)
// 一加 13 vbat_uv -> 2800mV
// 目标：跨 ColorOS 15 / 16 / 17 通用
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define UV_TARGET_MV 2800

struct uv_sig {
	const char *sym;
	unsigned int off;
	u32 want;
	const char *desc;
};

/* 这些指令字在 ColorOS 15.0.0.126 / 16.0.0.212 / 17.0.0.100 上实测完全一致 */
static const struct uv_sig uv_sigs[] = {
	{ "oplus_comm_update_vbat_uv_thr", 0x2c, 0xb9400108, "ldr w8,[x8]"   },
	{ "oplus_comm_update_vbat_uv_thr", 0x30, 0xb9000268, "str w8,[x19]"  },
	{ "vbat_uv_show",                  0x10, 0xaa0203e0, "mov x0,x2"     },
	{ "vbat_uv_show",                  0x20, 0x2a0803e2, "mov w2,w8"     },
};

/* 用全局 kprobe 解析地址，避免在栈上构造 struct kprobe */
static struct kprobe kp_verify;

static int uv_verify(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(uv_sigs); i++) {
		const struct uv_sig *s = &uv_sigs[i];
		u32 got;
		int ret;

		kp_verify.symbol_name = s->sym;
		kp_verify.addr = NULL;
		kp_verify.offset = 0;

		ret = register_kprobe(&kp_verify);
		if (ret) {
			pr_err("uv2800: 符号 %s 不存在 (err=%d) -- 版本不匹配，拒绝加载\n",
			       s->sym, ret);
			return ret;
		}
		got = *(u32 *)((u8 *)kp_verify.addr + s->off);
		unregister_kprobe(&kp_verify);
		kp_verify.addr = NULL;
		kp_verify.symbol_name = NULL;

		if (got != s->want) {
			pr_err("uv2800: %s+%#x = %#010x，期望 %#010x (%s) -- 版本不匹配，拒绝加载\n",
			       s->sym, s->off, got, s->want, s->desc);
			return -EINVAL;
		}
		pr_info("uv2800: 校验通过 %s+%#x (%s)\n", s->sym, s->off, s->desc);
	}
	return 0;
}

/*
 * Hook 1: oplus_comm_update_vbat_uv_thr(mms, out)
 *   +0x2c ldr w8,[x8] ; +0x30 str w8,[x19]
 * 在 +0x30 处把 x8 改成 2800 -> *out = 2800
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
 * Hook 2: vbat_uv_show(dev, attr, buf)
 *   +0x1c ldr w8,[x8,#chip_off]  (chip_off 跨版本会变)
 *   +0x20 mov w2, w8             (跨版本一致)
 * 在 +0x20 处把 x8 改成 2800 -> w2 = 2800 -> 打印 "2800"
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

static int __init uv2800_init(void)
{
	int ret;

	pr_info("uv2800: v2 init (target %d mV)\n", UV_TARGET_MV);

	ret = uv_verify();
	if (ret) {
		pr_err("uv2800: 指令校验失败，未注册任何 hook，模块不生效\n");
		return ret;
	}

	ret = register_kprobe(&kp_get);
	if (ret) {
		pr_err("uv2800: kp_get 注册失败 %d\n", ret);
		return ret;
	}

	ret = register_kprobe(&kp_show);
	if (ret) {
		pr_err("uv2800: kp_show 注册失败 %d\n", ret);
		unregister_kprobe(&kp_get);
		return ret;
	}

	pr_info("uv2800: v2 ready, vbat_uv -> %d mV (ColorOS 15/16/17 通用)\n",
		UV_TARGET_MV);
	return 0;
}

static void __exit uv2800_exit(void)
{
	if (kp_get.addr)
		unregister_kprobe(&kp_get);
	if (kp_show.addr)
		unregister_kprobe(&kp_show);
	pr_info("uv2800: unloaded\n");
}

module_init(uv2800_init);
module_exit(uv2800_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OnePlus 13: force vbat_uv to 2800mV (cross ColorOS 15/16/17)");
