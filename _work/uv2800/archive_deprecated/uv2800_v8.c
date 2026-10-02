// uv2800.c  (v8)  —— 跨 ColorOS 15/16/17 + 可用的手动回写
//
// 与 v7 的区别：
//   1) 删掉 oplus_target_term_voltage_vote_callback hook（不再需要运行时捕获 DT 值）
//   2) restore 参数改为接受【显式电压】：echo 3250 > .../restore
//   3) 按 profile 选择 setter 的调用 ABI：
//        ColorOS 16/17 : int  oplus_fg_set_deep_term_volt(dev, int volt)
//        ColorOS 15    : int  oplus_fg_set_deep_term_volt(dev, int *volt)
//   4) 三版本都支持回写，不需要 restore_ok 标志
//
// 为什么值可以显式给？
//   原值是【计算值】：
//       目标电压 = term_coeff 表中「最后一条 count <= 当前深度放电次数」的电压
//   COS17 真机验证：count=1734 → 3250（与驱动日志完全一致）
//   COS15 的表结构相同但数值不同（350~600 档），所以必须读实时 DT，不能硬编码。
//   计算放在用户态脚本里（action.sh），模块只负责按正确 ABI 写回。
//
// ★ kCFI 注意事项（v4 崩溃的教训）
//   在 CONFIG_CFI_CLANG=y 且未开 CFI_PERMISSIVE 的内核上，
//   模块里任何「函数指针调用内核函数」都会生成 kCFI 类型哈希校验，
//   原型不匹配 → brk → panic。用 no_sanitize("kcfi") 跳过校验。
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define UV_TARGET_MV 2800

/* ================= profile（跨版本） ================= */
struct uv_profile {
	const char *name;
	unsigned int get_off;
	u32 get_want;
	int get_reg;
	unsigned int set_off;
	u32 set_want;
	int set_reg;
	int set_ptr;          /* 1 = setter 第二参数是 int*（COS15）；0 = int（COS16/17）*/
};

static const struct uv_profile uv_profiles[] = {
	{
		.name = "ColorOS 16/17",
		.get_off = 0xe0, .get_want = 0xb9000263, .get_reg = 3,
		.set_off = 0x34, .set_want = 0x2a0103f3, .set_reg = 1,
		.set_ptr = 0,
	},
	{
		.name = "ColorOS 15",
		.get_off = 0x78, .get_want = 0xb9000283, .get_reg = 3,
		.set_off = 0x58, .set_want = 0xb90017e9, .set_reg = 9,
		.set_ptr = 1,
	},
};

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

static int cur_get_reg, cur_set_reg, cur_set_ptr;
static int cur_profile_idx = -1;
static const char *cur_profile = "none";

/* ============ 回写所需信息 ============ */
static void *uv_dev;          /* 从 getter 入口 x0 捕获 */
static void *uv_set_addr;     /* oplus_fg_set_deep_term_volt 地址 */
static int   uv_bypass;       /* 1 = 放行所有 hook（回写后进入恢复模式）*/
static int   uv_last_volt;    /* 最近一次回写的电压（只用于 get 显示）*/

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
		cur_set_ptr = p->set_ptr;
		cur_profile_idx = i;
		cur_profile = p->name;
		pr_info("uv2800: 匹配 profile [%s]  getter+%#x setter+%#x ABI=%s\n",
			p->name, p->get_off, p->set_off,
			p->set_ptr ? "(dev,int*)" : "(dev,int)");
		return 0;
	}
	return -ENOENT;
}

/* ================= 回写 ================= */
static noinline __attribute__((no_sanitize("kcfi")))
int uv_call_setter_val(void *dev, int volt, void *fn)
{
	int (*f)(void *, int) = fn;
	return f(dev, volt);
}

static noinline __attribute__((no_sanitize("kcfi")))
int uv_call_setter_ptr(void *dev, int *volt, void *fn)
{
	int (*f)(void *, int *) = fn;
	return f(dev, volt);
}

static int uv_do_restore(int volt)
{
	int rc;

	if (!uv_dev || !uv_set_addr) {
		pr_warn("uv2800: 信息不全 (dev=%px set=%px)，无法回写\n",
			uv_dev, uv_set_addr);
		return -EAGAIN;
	}
	if (volt < 2000 || volt > 5000) {
		pr_warn("uv2800: 电压 %d mV 超出合理范围 (2000~5000)，拒绝回写\n", volt);
		return -EINVAL;
	}

	/* 先永久放行所有 hook，避免我们自己的 setter hook 把回写值又改掉 */
	uv_bypass = 1;

	pr_info("uv2800: 回写 %d mV -> oplus_fg_set_deep_term_volt(%px) ABI=%s\n",
		volt, uv_set_addr, cur_set_ptr ? "(dev,int*)" : "(dev,int)");

	if (cur_set_ptr)
		rc = uv_call_setter_ptr(uv_dev, &volt, uv_set_addr);
	else
		rc = uv_call_setter_val(uv_dev, volt, uv_set_addr);

	uv_last_volt = volt;
	pr_info("uv2800: 回写返回 %d，已进入恢复模式（所有 hook 放行）\n", rc);
	return rc;
}

/* restore 参数：写入电压值即触发回写 */
static int uv_restore_val;

static int uv_restore_set(const char *val, const struct kernel_param *kp)
{
	int v = 0, i, neg = 0;

	for (i = 0; val[i] == ' '; i++)
		;
	if (val[i] == '-') { neg = 1; i++; }
	for (; val[i] >= '0' && val[i] <= '9'; i++)
		v = v * 10 + (val[i] - '0');
	if (neg)
		v = -v;

	uv_restore_val = v;

	if (v >= 2000 && v <= 5000)
		uv_do_restore(v);
	else if (v != 0)
		pr_warn("uv2800: 写入 %d 不是有效电压（应写 2000~5000，如 3250）\n", v);

	return 0;
}

static int uv_restore_get(char *buf, const struct kernel_param *kp)
{
	int v = uv_last_volt;
	char tmp[12];
	int n = 0, i;

	if (v == 0) {
		tmp[n++] = '0';
	} else {
		if (v < 0) { tmp[n++] = '-'; v = -v; }
		{
			char rev[12];
			int r = 0;
			while (v > 0) { rev[r++] = '0' + (v % 10); v /= 10; }
			for (i = r - 1; i >= 0; i--)
				tmp[n++] = rev[i];
		}
	}
	tmp[n] = '\0';
	for (i = 0; i < n; i++)
		buf[i] = tmp[i];
	return n;
}

static const struct kernel_param_ops uv_restore_ops = {
	.set = uv_restore_set,
	.get = uv_restore_get,
};
module_param_cb(restore, &uv_restore_ops, &uv_restore_val, 0644);
MODULE_PARM_DESC(restore, "write a voltage (e.g. 3250) to write it back to ADSP");

/* ================= hooks ================= */
static int uv_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_get = {
	.symbol_name = "oplus_comm_update_vbat_uv_thr",
	.offset = 0x30,
	.pre_handler = uv_get,
};
static int uv_get(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass)
		regs->regs[8] = UV_TARGET_MV;
	return 0;
}

static int uv_show(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_show = {
	.symbol_name = "vbat_uv_show",
	.offset = 0x20,
	.pre_handler = uv_show,
};
static int uv_show(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass)
		regs->regs[8] = UV_TARGET_MV;
	return 0;
}

static int uv_term_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_get = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.pre_handler = uv_term_get,
};
static int uv_term_get(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass)
		regs->regs[cur_get_reg] = UV_TARGET_MV;
	return 0;
}

/* getter 入口：捕获 dev 指针（三版本入口都是 x0 = dev）*/
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

static int uv_term_set(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_set = {
	.symbol_name = "oplus_fg_set_deep_term_volt",
	.pre_handler = uv_term_set,
};
static int uv_term_set(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass)
		regs->regs[cur_set_reg] = UV_TARGET_MV;
	return 0;
}

static int __init uv2800_init(void)
{
	int ret, n = 0;
	u32 tmp;

	pr_info("uv2800: v8 init (target %d mV)\n", UV_TARGET_MV);

	ret = uv_verify_display();
	if (ret)
		return ret;

	/* 取 setter 地址（回写用）*/
	if (!uv_read_word("oplus_fg_set_deep_term_volt", 0, &tmp)) {
		kp_verify.symbol_name = "oplus_fg_set_deep_term_volt";
		kp_verify.addr = NULL;
		if (!register_kprobe(&kp_verify)) {
			uv_set_addr = (void *)kp_verify.addr;
			unregister_kprobe(&kp_verify);
			kp_verify.addr = NULL;
			kp_verify.symbol_name = NULL;
		}
	}

	ret = uv_detect_profile();
	if (ret) {
		pr_err("uv2800: 未匹配到 profile -- 只注册显示 hook\n");
	} else {
		kp_term_get.offset = uv_profiles[cur_profile_idx].get_off;
		kp_term_set.offset = uv_profiles[cur_profile_idx].set_off;

		if (!register_kprobe(&kp_term_get)) n++;
		if (!register_kprobe(&kp_term_set)) n++;
		if (!register_kprobe(&kp_term_entry)) n++;
	}

	if (!register_kprobe(&kp_get)) n++;
	else { pr_err("uv2800: kp_get 失败\n"); return -EIO; }
	if (!register_kprobe(&kp_show)) n++;
	else { pr_err("uv2800: kp_show 失败\n"); return -EIO; }

	pr_info("uv2800: v8 ready, %d 个 hook, profile=[%s], setter=%px\n",
		n, cur_profile, uv_set_addr);
	pr_info("uv2800: 回写入口 /sys/module/uv2800/parameters/restore（写电压值，如 3250）\n");
	return 0;
}

static void __exit uv2800_exit(void)
{
	if (kp_term_entry.addr)  unregister_kprobe(&kp_term_entry);
	if (kp_term_set.addr)    unregister_kprobe(&kp_term_set);
	if (kp_term_get.addr)    unregister_kprobe(&kp_term_get);
	if (kp_get.addr)         unregister_kprobe(&kp_get);
	if (kp_show.addr)        unregister_kprobe(&kp_show);
	pr_info("uv2800: unloaded\n");
}

module_init(uv2800_init);
module_exit(uv2800_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OnePlus 13: deep term voltage 2800mV, cross ColorOS 15/16/17, manual writeback");
