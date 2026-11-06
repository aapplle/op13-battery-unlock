// uv2800.c - OnePlus 13 关机电压与电量计终止电压控制模块
//
// 挂钩点概览：
//   kp_get        : oplus_comm_update_vbat_uv_thr 内部，将驱动更新的 vbat_uv 覆写为 uv_target_mv
//   kp_show       : vbat_uv_show 内部，使 sysfs 读出值与驱动内部值保持一致
//   kp_term_get   : oplus_fg_get_deep_term_volt 内部，将驱动读到的终止电压覆写为 uv_term_mv
//   kp_term_set   : oplus_fg_set_deep_term_volt 内部，拦截驱动回写并将写入值统一为 uv_term_mv
//   kp_term_entry : getter 入口（offset 0），捕获电量计 device 指针（uv_dev）
//   kp_ddrc       : oplus_fg_set_batt_deep_dischg_count 入口，用于无充电事件时主动补捕获 uv_dev
//
// 模块参数：
//   uv_target_mv / uv_shutdown_mv : 关机电压目标值 V_s（范围 2000~5000，默认 2800）
//   uv_term_mv / uv_adsp_mv       : 电量计终止电压 T（随 V_s 自动派生，不可独立覆盖）
//   uv_apply                      : 写任意值重放 votable override，读回 1 表示全部就绪
//   adsp_read                     : 写任意值触发直读 ADSP 当前 deep_term_volt，读回上次结果
//   adsp_write                    : 写电压值主动调用 setter 写入 ADSP，不改变 hook 状态
//   resume                        : 写 1 启用所有 hook，写 0 旁路所有 hook；读回当前 uv_bypass 状态
//   adsp_debug                    : 1 = 开启 adsp_read 的 dmesg 诊断日志
//
// 注意事项：
//   1. kp_term_get 必须挂在函数内部写回指令之前，入口处目标寄存器尚未写入，在入口修改会被后续指令覆盖。
//   2. 目标内核启用了 CONFIG_CFI_CLANG，通过函数指针调用内核符号时需加 no_sanitize("kcfi") 避免触发 kCFI 异常。
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define UV_TARGET_MV 2800

/*
 * uv_target_mv 为关机电压目标值（V_s），uv_term_mv 为电量计学习终止电压（T）。
 * 正常解耦时设为用户目标值；恢复原厂（skip）时设为原厂值，通过 hook 直接向驱动返回。
 */
static int uv_target_mv = UV_TARGET_MV;
static int uv_term_mv = 2540;
static int uv_adsp_mv = 2540;
static int uv_shutdown_mv = UV_TARGET_MV;

static void uv_override_apply(void);

/*
 * 由关机电压 V_s 派生电量计终止电压 T：
 * V_s < 3060 时按 2 * V_s - 3060 计算；
 * V_s >= 3060（如恢复原厂值）时保持 V_s 原值不变。
 */
static int uv_derive_term(int vs)
{
	int t = (vs < 3060) ? (2 * vs - 3060) : vs;

	if (t < 2000)
		t = 2000;
	if (t > 5000)
		t = 5000;
	return t;
}

static int uv_target_mv_set(const char *val, const struct kernel_param *kp)
{
	int v;

	if (kstrtoint(val, 10, &v))
		return -EINVAL;
	if (v < 2000 || v > 5000) {
		pr_warn("uv2800: uv_target_mv %d mV 超出范围 2000~5000，拒绝\n", v);
		return -EINVAL;
	}
	uv_target_mv = v;
	uv_shutdown_mv = v;
	uv_term_mv = uv_derive_term(v);
	uv_adsp_mv = uv_term_mv;
	uv_override_apply();
	return 0;
}

static int uv_itoa(char *buf, int v);

static int uv_target_mv_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_target_mv);
}

static const struct kernel_param_ops uv_target_mv_ops = {
	.set = uv_target_mv_set,
	.get = uv_target_mv_get,
};
module_param_cb(uv_target_mv, &uv_target_mv_ops, &uv_target_mv, 0644);
MODULE_PARM_DESC(uv_target_mv, "forced vbat_uv value in mV (default 2800, range 2000~5000)");

/*
 * uv_adsp_mv / uv_term_mv：电量计终止电压参数。
 * 数值始终由 uv_target_mv 派生，忽略外部独立写入的值。
 */
static int uv_adsp_mv_set(const char *val, const struct kernel_param *kp)
{
	int v;

	if (kstrtoint(val, 10, &v))
		return -EINVAL;
	uv_term_mv = uv_derive_term(uv_target_mv);
	uv_adsp_mv = uv_term_mv;
	if (v != uv_term_mv)
		pr_info("uv2800: term 由 V_s=%d 派生为 %d mV（忽略写入 %d）\n",
			uv_target_mv, uv_term_mv, v);
	uv_override_apply();
	return 0;
}

static int uv_adsp_mv_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_term_mv);
}

static const struct kernel_param_ops uv_adsp_mv_ops = {
	.set = uv_adsp_mv_set,
	.get = uv_adsp_mv_get,
};
module_param_cb(uv_adsp_mv, &uv_adsp_mv_ops, &uv_adsp_mv, 0644);
MODULE_PARM_DESC(uv_adsp_mv, "legacy alias of uv_term_mv (QBG learning term)");

module_param_cb(uv_term_mv, &uv_adsp_mv_ops, &uv_term_mv, 0644);
MODULE_PARM_DESC(uv_term_mv, "QBG learning term in mV (default 2540, range 2000~5000)");

module_param_cb(uv_shutdown_mv, &uv_target_mv_ops, &uv_shutdown_mv, 0644);
MODULE_PARM_DESC(uv_shutdown_mv, "AP shutdown voltage V_s in mV (default 2800)");

/* 跨版本指令偏移与寄存器配置 */
struct uv_profile {
	const char *name;
	unsigned int get_off;
	u32 get_want;
	int get_reg;
	unsigned int set_off;
	u32 set_want;
	int set_reg;
	int set_ptr;          /* 1: setter 第二参数为 int*（COS15）；0: int（COS16/17）*/
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
static int uv_override_expected = 4;
static int cur_profile_idx = -1;
static const char *cur_profile = "none";

/* 直读与回写运行状态 */
static void *uv_dev;          /* 电量计 device 指针 */
static void *uv_set_addr;     /* oplus_fg_set_deep_term_volt 函数地址 */
static int   uv_bypass;       /* 1 = 旁路所有 hook */
static int   uv_last_volt;    /* 最近一次通过 adsp_write 写入的电压 */
static int   uv_self_write;   /* 1 = 当前 setter 调用由本模块发起，hook 放行 */
static int   uv_self_read;    /* 1 = 当前 getter 调用由本模块发起，hook 放行 */
static void *uv_get_addr;     /* oplus_fg_get_deep_term_volt 函数地址 */
static int   uv_adsp_raw;     /* 最近一次直读到的 ADSP 终止电压 */

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
		/* ColorOS 15 仅存在 GAUGE_TERM / GAUGE_SHUTDOWN 两个电压 votable，ColorOS 16/17 为四个 */
		uv_override_expected = (i == 1) ? 2 : 4;
		pr_info("uv2800: 匹配 profile [%s]  getter+%#x setter+%#x ABI=%s\n",
			p->name, p->get_off, p->set_off,
			p->set_ptr ? "(dev,int*)" : "(dev,int)");
		return 0;
	}
	return -ENOENT;
}

/*
 * votable 覆写：
 * 驱动的电压 votable 聚合策略均为 VOTE_MAX，普通投票无法压低原厂高阈值，
 * 需通过 vote_override 强制指定 TERM 与 SHUTDOWN 的有效票值。
 */
static void *uv_find_votable_fn;
static void *uv_vote_override_fn;
static int uv_override_ok;
static int uv_override_last_mv;
static int uv_override_last_term;

static const char * const uv_override_names[] = {
	"GAUGE_TERM_VOLTAGE",
	"TARGET_TERM_VOLTAGE",
	"GAUGE_SHUTDOWN_VOLTAGE",
	"TARGET_SHUTDOWN_VOLTAGE",
};

static void *uv_kprobe_sym(const char *sym)
{
	struct kprobe kp = { .symbol_name = sym };
	void *addr = NULL;

	if (!register_kprobe(&kp)) {
		addr = kp.addr;
		unregister_kprobe(&kp);
	}
	return addr;
}

static noinline __attribute__((no_sanitize("kcfi")))
void *uv_call_find_votable(const char *name, void *fn)
{
	void *(*f)(const char *) = fn;

	return f(name);
}

static noinline __attribute__((no_sanitize("kcfi")))
int uv_call_vote_override(void *v, const char *client, bool active, int mv,
			  bool force, void *fn)
{
	int (*f)(void *, const char *, bool, int, bool) = fn;

	return f(v, client, active, mv, force);
}

static void uv_override_apply(void)
{
	int i, found = 0;

	uv_override_ok = 0;
	if (!uv_find_votable_fn || !uv_vote_override_fn) {
		uv_find_votable_fn = uv_kprobe_sym("find_votable");
		uv_vote_override_fn = uv_kprobe_sym("vote_override");
	}
	if (!uv_find_votable_fn || !uv_vote_override_fn) {
		pr_warn_once("uv2800: find_votable/vote_override 不可用，无法 override\n");
		return;
	}

	for (i = 0; i < ARRAY_SIZE(uv_override_names); i++) {
		void *v = uv_call_find_votable(uv_override_names[i],
					       uv_find_votable_fn);
		int mv = (i < 2) ? uv_term_mv : uv_target_mv;
		int rc;

		if (!v)
			continue;
		rc = uv_call_vote_override(v, "UV2800", true, mv,
					   false, uv_vote_override_fn);
		if (rc) {
			pr_warn("uv2800: vote_override %s=%d 失败 rc=%d\n",
				uv_override_names[i], mv, rc);
			continue;
		}
		found++;
	}

	uv_override_ok = (found >= uv_override_expected);
	if (found && (uv_override_last_mv != uv_target_mv ||
		      uv_override_last_term != uv_term_mv || !uv_override_ok)) {
		pr_info("uv2800: votable override %d/%d (expected %d) term=%d shutdown=%d mV\n",
			found, (int)ARRAY_SIZE(uv_override_names),
			uv_override_expected, uv_term_mv, uv_target_mv);
		uv_override_last_mv = uv_target_mv;
		uv_override_last_term = uv_term_mv;
	}
}

static int uv_apply_set(const char *val, const struct kernel_param *kp)
{
	uv_override_apply();
	return 0;
}

static int uv_apply_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_override_ok ? 1 : 0);
}

static const struct kernel_param_ops uv_apply_ops = {
	.set = uv_apply_set,
	.get = uv_apply_get,
};
module_param_cb(uv_apply, &uv_apply_ops, &uv_override_ok, 0644);
MODULE_PARM_DESC(uv_apply, "write to re-apply four votable overrides; read 1 when all four ready");

static void uv_override_clear(void)
{
	int i;

	if (!uv_find_votable_fn || !uv_vote_override_fn)
		return;
	for (i = 0; i < ARRAY_SIZE(uv_override_names); i++) {
		void *v = uv_call_find_votable(uv_override_names[i],
					       uv_find_votable_fn);
		if (v)
			uv_call_vote_override(v, "UV2800", false, 0, false,
					      uv_vote_override_fn);
	}
}

/* ADSP 终止电压写入封装 */
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

static int uv_itoa_raw(char *buf, int v);

/* 返回最近一次通过 adsp_write 写入的电压（保持无末尾换行格式） */
static int uv_lastvolt_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa_raw(buf, uv_last_volt);
}

/*
 * resume 参数：控制 hook 是否生效。
 * 写 1 令 uv_bypass=0（启用所有 hook），写 0 令 uv_bypass=1（旁路所有 hook）。
 * 读取时直接返回 uv_bypass 的当前状态（1 = 已旁路，0 = hook 生效）。
 */
static int uv_resume_val;

static int uv_resume_set(const char *val, const struct kernel_param *kp)
{
	int v;

	if (kstrtoint(val, 10, &v)) {
		pr_warn("uv2800: resume 无法解析 '%s'（应写 0 或 1）\n", val);
		return -EINVAL;
	}
	if (v != 0 && v != 1) {
		pr_warn("uv2800: resume 只接受 0 或 1（收到 %d）\n", v);
		return -EINVAL;
	}

	uv_resume_val = v;
	uv_bypass = v ? 0 : 1;

	if (v)
		pr_info("uv2800: resume=1，已退出恢复模式，所有 hook 重新生效\n");
	else
		pr_info("uv2800: resume=0，已进入恢复模式，所有 hook 放行\n");
	return 0;
}

static int uv_resume_get(char *buf, const struct kernel_param *kp)
{
	buf[0] = uv_bypass ? '1' : '0';
	return 1;
}

static const struct kernel_param_ops uv_resume_ops = {
	.set = uv_resume_set,
	.get = uv_resume_get,
};
module_param_cb(resume, &uv_resume_ops, &uv_resume_val, 0644);
MODULE_PARM_DESC(resume, "write 1 to exit restore mode (re-enable hooks), 0 to enter");

/* 整数转十进制字符串 */
static int uv_itoa_raw(char *buf, int v)
{
	int n = 0, i;

	if (v < 0) { buf[n++] = '-'; v = -v; }
	if (v == 0) {
		buf[n++] = '0';
	} else {
		char rev[12];
		int r = 0;
		while (v > 0) { rev[r++] = '0' + (v % 10); v /= 10; }
		for (i = r - 1; i >= 0; i--)
			buf[n++] = rev[i];
	}
	buf[n] = '\0';
	return n;
}

static int uv_itoa(char *buf, int v)
{
	int n = uv_itoa_raw(buf, v);

	buf[n++] = '\n';
	return n;
}

/* 主动调用驱动 setter 将指定电压写入 ADSP，通过 uv_self_write 穿透 setter hook */
static int uv_adsp_write_val;

static int uv_adsp_write_set(const char *val, const struct kernel_param *kp)
{
	int v, rc = 0;

	if (kstrtoint(val, 10, &v)) {
		pr_warn("uv2800: adsp_write 无法解析 '%s'（应写 2000~5000）\n", val);
		return -EINVAL;
	}

	uv_adsp_write_val = v;

	if (v >= 2000 && v <= 5000) {
		if (!uv_dev || !uv_set_addr) {
			pr_warn("uv2800: 信息不全 (dev=%px set=%px)\n", uv_dev, uv_set_addr);
			return -EAGAIN;
		}
		uv_self_write = 1;
		if (cur_set_ptr)
			rc = uv_call_setter_ptr(uv_dev, &v, uv_set_addr);
		else
			rc = uv_call_setter_val(uv_dev, v, uv_set_addr);
		uv_self_write = 0;
		uv_last_volt = v;
		pr_info("uv2800: [adsp_write] 写 %d mV，返回 %d（强制仍生效）\n", v, rc);
	} else if (v != 0) {
		pr_warn("uv2800: adsp_write 写入 %d 不是有效电压（应写 2000~5000）\n", v);
	}

	return 0;
}

static const struct kernel_param_ops uv_adsp_write_ops = {
	.set = uv_adsp_write_set,
	.get = uv_lastvolt_get,
};
module_param_cb(adsp_write, &uv_adsp_write_ops, &uv_adsp_write_val, 0644);
MODULE_PARM_DESC(adsp_write, "write voltage to ADSP without changing force state");

/* 控制 adsp_read 是否向 dmesg 打印诊断日志（默认关闭，减少轮询期的日志噪音） */
static bool uv_adsp_debug;
module_param_named(adsp_debug, uv_adsp_debug, bool, 0644);
MODULE_PARM_DESC(adsp_debug, "1 = print adsp_read diagnostics to dmesg (default 0)");

/* 主动调用驱动 getter 直读 ADSP 当前保存的 deep_term_volt，通过 uv_self_read 穿透 getter hook */
static noinline __attribute__((no_sanitize("kcfi")))
int uv_call_getter(void *dev, int *out, void *fn)
{
	int (*f)(void *, int *) = fn;
	return f(dev, out);
}

static int uv_adsp_read_set(const char *val, const struct kernel_param *kp)
{
	int out = 0, rc;

	if (uv_get_addr && uv_dev) {
		uv_self_read = 1;
		rc = uv_call_getter(uv_dev, &out, uv_get_addr);
		uv_self_read = 0;
		uv_adsp_raw = out;
		if (uv_adsp_debug)
			pr_info("uv2800: 直读 ADSP deep_term_volt = %d mV (rc=%d)\n", out, rc);
	} else {
		if (uv_adsp_debug)
			pr_warn("uv2800: 直读失败（uv_dev 未捕获 / get 地址未解析）\n");
	}
	return 0;
}

static int uv_adsp_read_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_adsp_raw);
}

static const struct kernel_param_ops uv_adsp_read_ops = {
	.set = uv_adsp_read_set,
	.get = uv_adsp_read_get,
};
module_param_cb(adsp_read, &uv_adsp_read_ops, &uv_adsp_raw, 0644);
MODULE_PARM_DESC(adsp_read, "write anything to read raw ADSP deep_term_volt");

/* kprobe 挂钩函数 */
static int uv_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_get = {
	.symbol_name = "oplus_comm_update_vbat_uv_thr",
	.offset = 0x30,
	.pre_handler = uv_get,
};
static int uv_get(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass)
		regs->regs[8] = uv_target_mv;
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
		regs->regs[8] = uv_target_mv;
	return 0;
}

/* 在 getter 写回结构体前将读出值替换为 uv_term_mv（本模块直读时放行） */
static int uv_term_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_get = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.pre_handler = uv_term_get,
};
static int uv_term_get(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass && !uv_self_read)
		regs->regs[cur_get_reg] = uv_term_mv;
	return 0;
}

/* 在 getter 入口捕获 x0（电量计 device 指针） */
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

/*
 * 在 oplus_fg_set_batt_deep_dischg_count 入口补捕获 uv_dev。
 * 该函数入口的 x0 与 getter 使用同一个 device 指针，用户态向 deep_dischg_counts
 * 写入当前原值即可无副作用地触发此入口，无需等待充电器插拔事件。
 */
static int uv_ddrc_entry(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_ddrc = {
	.symbol_name = "oplus_fg_set_batt_deep_dischg_count",
	.offset = 0,
	.pre_handler = uv_ddrc_entry,
};
static int uv_ddrc_entry(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_dev) {
		uv_dev = (void *)regs->regs[0];
		pr_info("uv2800: 从 deep_dischg 入口捕获 device=%px\n", uv_dev);
	}
	return 0;
}

/* 在 setter 内部将驱动发起的写入值替换为 uv_term_mv（本模块主动写入时放行） */
static int uv_term_set(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_set = {
	.symbol_name = "oplus_fg_set_deep_term_volt",
	.pre_handler = uv_term_set,
};
static int uv_term_set(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass && !uv_self_write)
		regs->regs[cur_set_reg] = uv_term_mv;
	return 0;
}

static int __init uv2800_init(void)
{
	int ret, n = 0;

	pr_info("uv2800: v12.0 init (vbat_uv=%d mV, adsp=%d mV)\n",
		uv_target_mv, uv_adsp_mv);

	ret = uv_verify_display();
	if (ret)
		return ret;

	uv_get_addr = uv_kprobe_sym("oplus_fg_get_deep_term_volt");
	uv_set_addr = uv_kprobe_sym("oplus_fg_set_deep_term_volt");

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

	if (!register_kprobe(&kp_ddrc)) n++;
	else pr_warn("uv2800: kp_ddrc 注册失败（deep_dischg 入口），回退到插拔捕获\n");

	/* 若加载时 votable 尚未创建，后续由 service.sh 写 uv_apply 触发重放 */
	uv_override_apply();
	if (!uv_override_ok)
		pr_info("uv2800: votable 尚未就绪，等待 service.sh 写 uv_apply\n");

	pr_info("uv2800: v12 ready, %d 个 hook, profile=[%s], vbat_uv=%d adsp=%d\n",
		n, cur_profile, uv_target_mv, uv_adsp_mv);
	pr_info("uv2800: 回写入口 /sys/module/uv2800/parameters/adsp_write（写电压值，如 3250）\n");
	return 0;
}

static void __exit uv2800_exit(void)
{
	uv_override_clear();
	if (kp_ddrc.addr)        unregister_kprobe(&kp_ddrc);
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
MODULE_DESCRIPTION("OnePlus 13: native SOC calibration via deep_term_volt, cross ColorOS 15/16/17");
