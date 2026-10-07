// SPDX-License-Identifier: GPL-2.0-only
// uv2800.c —— 原生 SOC 校准方案（关机电压自定义 + ADSP 自动派生）
//
// ============ 功能总览 ============
//  ① uv_get ：挂钩 oplus_comm_update_vbat_uv_thr，把驱动算出的关机电压
//             vbat_uv 强制为运行时参数 uv_target_mv（默认 2800，即用户可调的
//             关机电压 V_s）。
//  ② uv_show：挂钩 vbat_uv_show（sysfs 读出侧），同样返回 uv_target_mv ——
//             驱动内部值与状态栏读到的值必须一致。
//  ③ uv_term_get：挂钩 getter 内部 get_off，把驱动从 ADSP 读到的终止电压
//             （空电点）强制为 uv_adsp_mv（默认 2540）。
//  ④ uv_term_set：挂钩 setter 内部 set_off，驱动纠偏写回时把写入值统一为
//             uv_adsp_mv。
//  uv_term_entry：在 getter 入口（offset 0）捕获 dev 指针（uv_dev），
//             供 adsp_read / adsp_write 复用同一个 dev。
//  uv_ddrc_entry：在 deep_dischg 入口补捕获 uv_dev，不依赖驱动 vote（插拔）。
//
//  用户态入口（module param）：
//    uv_target_mv  关机电压强制值（2000~5000 钳制，默认 2800）
//    uv_adsp_mv    ADSP 终止电压目标（默认 2540）
//    adsp_read     写任意值 -> 直读 ADSP 里保存的 deep_term_volt 真值
//    adsp_write    写电压值 -> 主动调用 setter 回写 ADSP
//    resume        写 1 退出恢复模式（hook 重新生效），写 0 进入
//    adsp_debug    1 = 打开 adsp_read 的内核侧诊断输出
//
// ============ 参数解析 ============
//  统一用内核导出的 kstrtoint()，不再手写 ASCII atoi：后者对「非数字字符」
//  静默截断，行为有歧义。kstrtoint 的 CRC 需在 Module.symvers 中（构建流程已处理）。
//
// ============ 挂钩点为什么这样选 ============
//  kp_term_get 挂钩在 getter 函数【内部】get_off 处（该偏移是
//  "str w<get_reg>,[...]" 指令所在，改寄存器必须在它之前），
//  而 kp_term_entry 才挂钩在入口 offset 0 捕获 dev。
//  两者【不能】合并到入口：get_off 之前的指令会刷新目标寄存器，
//  入口改值会被覆盖。
//
// ============ 核心机制 ============
//   · deep_term_volt 就是电量计的 Termination Voltage（空电点），
//     电量计【实时读取】它，满电状态切换（充满/满电拔插充电器）时重算 fcc。
//   · 实测：term=2800 时 fcc 4366→4956（+13.5%）；term=2600 时 fcc→~5000；
//     默认 term=2540 时驱动上报 fcc=5020。
//   · 原生库仑计量与负载无关 → 高倍率放电天然正确（显示层方案做不到）。
//   · 关机电压由 ①uv_get hook 强制为运行时参数 uv_target_mv（默认 2800）；
//     ADSP term 由 uv_adsp_mv 独立设定（默认 2540）。两者数值独立，但 ③ 读值
//     会进入驱动关机票计算，并非"完全解耦"——详见各 hook 处注释。
//
// ============ 兼容性 ============
//  挂钩偏移由 profile 表按驱动指令字自适应选择（ColorOS 15 / 16 / 17），
//  并用 uv_verify_display() 逐条校验指令字，不匹配就【拒绝加载】——
//  宁可模块不加载，也不在未知内核上乱改寄存器；profile 未匹配时只注册
//  ①② 显示 hook，不动 ③④。
//  口径：C15/16/17 三驱动静态核对通过 + ColorOS 16 / 内核 6.6.118 真机验证；
//  C15/C17 无真机数据。
//
// ★ kCFI 注意事项（崩溃教训）
//   在 CONFIG_CFI_CLANG=y 且未开 CFI_PERMISSIVE 的内核上，
//   模块里任何「函数指针调用内核函数」都会生成 kCFI 类型哈希校验，
//   原型不匹配 → brk → panic。用 no_sanitize("kcfi") 跳过校验
//   （见 uv_call_setter_val / uv_call_setter_ptr / uv_call_getter）。
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/smp.h>

#define UV_TARGET_MV 2800

/* ------------------------------------------------------------------
 * uv_target_mv（运行时参数，写入口有 2000~5000 钳制）：①/② hook 的强制值，
 * 默认 2800，即用户可调的关机电压 V_s。
 *
 * 【为什么做成运行时参数】恢复模式（uv_bypass=1）会让 ①/② 旁路，vbat_uv 落到
 *   驱动自己算出的值。要"恢复原厂显示"又不永久放弃 hook，最直接的办法是把
 *   hook 的返回值做成参数：skip 时设为原值（如 3250），解耦时设为
 *   V_s（默认 2800），hook 直接返回该值。
 *
 * 实测：只要 hook 生效，vbat_uv 就是 uv_target_mv 的【即时镜像】——
 *   改 3000/3100/3250 逐字跟随，零延迟、不需要任何 vote/插拔。
 *   vbat_uv 不跟随的唯一原因是 hook 被旁路，不是"驱动缓存未刷新"。
 *   （service.sh / action.sh 有同款说明。）
 * ------------------------------------------------------------------ */
static int uv_target_mv = UV_TARGET_MV;

/* uv_target_mv 范围钳制
 * 任意整数都会直接成为 vbat_uv，必须限制在合理范围内
 * （与 adsp_write 的 2000~5000 钳制一致）。*/
static int uv_voltage_set(const char *val, const struct kernel_param *kp)
{
	int v;

	if (kstrtoint(val, 10, &v))
		return -EINVAL;
	if (v < 2000 || v > 5000) {
		pr_warn("uv2800: 电压目标 %d mV 超出范围 2000~5000\n", v);
		return -EINVAL;
	}
	WRITE_ONCE(*(int *)kp->arg, v);
	return 0;
}

static int uv_itoa(char *buf, int v);

static int uv_voltage_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, READ_ONCE(*(int *)kp->arg));
}

static const struct kernel_param_ops uv_voltage_ops = {
	.set = uv_voltage_set,
	.get = uv_voltage_get,
};
module_param_cb(uv_target_mv, &uv_voltage_ops, &uv_target_mv, 0644);
MODULE_PARM_DESC(uv_target_mv, "forced vbat_uv value in mV (default 2800, range 2000~5000)");

/* ------------------------------------------------------------------
 * uv_adsp_mv：ADSP（电量计终止电压 / 空电点）的目标值，独立于 uv_target_mv。
 *
 * 【为什么必须独立】uv_term_get / uv_term_set 若复用 uv_target_mv，解耦态下
 *   ADSP 目标（如 2540）与关机电压（2800）就被混为一谈：③ 让驱动"读到"的值
 *   恰好等于 ④ 会强制成的值，④ 平时因此不触发；但实测（独立审计 §3c.3）
 *   驱动会定期把 ADSP 纠回它在 ③ 处读到的值，那一刻 ④ 会执行并把写入值统一成
 *   目标值 —— ③④ 构成自洽反馈环：③ 决定"驱动以为当前值是多少"，④ 是驱动
 *   纠偏时的保险丝，不是死代码。独立参数让 ③④ 的目标与脚本写入的 ADSP 值一致。
 *   另注：③ 的读值进入驱动关机票计算，所以本参数同时影响空电点与关机票。
 *
 * 【脚本职责】每次 adsp_write 之前，先写本参数保证 ③④ 目标一致：
 *   echo 2540 > /sys/module/uv2800/parameters/uv_adsp_mv
 *   echo 2540 > /sys/module/uv2800/parameters/adsp_write
 * ------------------------------------------------------------------ */
static int uv_adsp_mv = 2540;	/* 默认：V_s=2800, FLOOR=3060 -> 2800-(3060-2800)=2540 */
module_param_cb(uv_adsp_mv, &uv_voltage_ops, &uv_adsp_mv, 0644);
MODULE_PARM_DESC(uv_adsp_mv, "ADSP deep_term_volt target in mV (default 2540)");

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
static void *uv_dev;          /* 从 getter 入口 x0（或 deep_dischg 入口）捕获 */
static void *uv_set_addr;     /* oplus_fg_set_deep_term_volt 地址 */
static int   uv_bypass;       /* 1 = 放行所有 hook（回写后进入恢复模式）*/
static int   uv_last_volt;    /* 最近一次回写的电压（只用于 get 显示）*/
/* sysfs 参数回调由模块参数锁串行执行；只旁路当前调用任务，其他任务照常强制。
 * 厂商函数可以睡眠/迁移 CPU，故这里使用 task 身份而非 CPU 标志。 */
static struct task_struct *uv_write_task;
static struct task_struct *uv_read_task;
static void *uv_get_addr;     /* oplus_fg_get_deep_term_volt 地址 */
static int   uv_adsp_raw;     /* 直读到的 ADSP 原值 */
static bool uv_hooks_ready;   /* 全部必要探针注册成功后才允许修改寄存器 */
static bool uv_adsp_ready;    /* profile 和 ADSP 必要探针均已验证 */

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

/* adsp_write 的 get：显示最近一次回写的电压（仅用于人读）*/
static int uv_lastvolt_get(char *buf, const struct kernel_param *kp)
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

/* ------------------------------------------------------------------
 * resume 参数：写 1 退出「恢复模式」，让所有 hook 重新生效。
 *
 * 【为什么需要】内核里【没有】任何自动复位 uv_bypass 的路径 —— 一旦被置 1，
 *   所有 hook 就【永久】放行，只能由用户态显式写回。
 *   但用户「执行」验证恢复功能后，若想继续用模块（rm skip + 重启），hook 仍是
 *   旁路状态：ADSP 虽重新解耦，vbat_uv 却停在驱动算出的 3200/3250 而非 2800。
 *
 * 本参数提供显式出口，【无需 rmmod+insmod】—— 那样会丢掉 uv_dev（getter 捕获的
 * 设备指针），需要重新触发一次捕获（deep_dischg 入口 uv_capture_dev，或插拔）
 * 才能回写 ADSP。
 *
 *   echo 1 > /sys/module/uv2800/parameters/resume   # 退出恢复模式（hook 生效）
 *   echo 0 > /sys/module/uv2800/parameters/resume   # 再次进入恢复模式
 *   读该参数可得当前状态（1 = 已旁路 / 0 = hook 生效）
 * ------------------------------------------------------------------ */
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
	WRITE_ONCE(uv_bypass, v ? 0 : 1);

	if (v)
		pr_info("uv2800: resume=1，已退出恢复模式，所有 hook 重新生效\n");
	else
		pr_info("uv2800: resume=0，已进入恢复模式，所有 hook 放行\n");
	return 0;
}

/* 读：直接反映 uv_bypass，避免与 uv_resume_val 不一致 */
static int uv_resume_get(char *buf, const struct kernel_param *kp)
{
	buf[0] = READ_ONCE(uv_bypass) ? '1' : '0';
	return 1;
}

static const struct kernel_param_ops uv_resume_ops = {
	.set = uv_resume_set,
	.get = uv_resume_get,
};
module_param_cb(resume, &uv_resume_ops, &uv_resume_val, 0644);
MODULE_PARM_DESC(resume, "write 1 to exit restore mode (re-enable hooks), 0 to enter");

/* --- 小工具：整数转字符串（scnprintf 未导出）--- */
static int uv_itoa(char *buf, int v)
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
	buf[n++] = '\n';
	return n;
}

/* --- adsp_write：只写电压，【不改变】强制状态 --- */
static int uv_adsp_write_val;

static int uv_adsp_write_set(const char *val, const struct kernel_param *kp)
{
	void *dev, *fn;
	int v, rc;

	if (kstrtoint(val, 10, &v)) {
		pr_warn("uv2800: adsp_write 无法解析 '%s'（应写 2000~5000）\n", val);
		return -EINVAL;
	}

	if (v < 2000 || v > 5000)
		return -EINVAL;
	if (!smp_load_acquire(&uv_adsp_ready))
		return -EOPNOTSUPP;
	dev = READ_ONCE(uv_dev);
	fn = uv_set_addr;
	if (!dev || !fn)
		return -EAGAIN;

	WRITE_ONCE(uv_write_task, current);
	if (cur_set_ptr)
		rc = uv_call_setter_ptr(dev, &v, fn);
	else
		rc = uv_call_setter_val(dev, v, fn);
	WRITE_ONCE(uv_write_task, NULL);
	pr_info("uv2800: [adsp_write] 写 %d mV，返回 %d\n", v, rc);
	if (rc)
		return rc < 0 ? rc : -EIO;
	uv_adsp_write_val = v;
	uv_last_volt = v;
	return 0;
}

static const struct kernel_param_ops uv_adsp_write_ops = {
	.set = uv_adsp_write_set,
	.get = uv_lastvolt_get,
};
module_param_cb(adsp_write, &uv_adsp_write_ops, &uv_adsp_write_val, 0644);
MODULE_PARM_DESC(adsp_write, "write voltage to ADSP without changing force state");

/* ------------------------------------------------------------------
 * adsp_debug 参数：打开 adsp_read 的内核侧诊断输出（默认关闭）。
 *
 * 【为什么默认关】adsp_read 是轮询式接口：uv_dev 未捕获时（越狱模式开机、
 *   软重启后）每次读都打印一行失败，而用户态探测循环每秒读一次 ->
 *   每次开机最多 10 行 dmesg 噪音（service.sh 探测循环 10 次），其中真正有用的信息只有「多久才就绪」。
 *   现在默认静默，改由用户态探测循环结束时汇总一条（见 service.sh）。
 *   需要现场排查时再打开：
 *
 *   echo 1 > /sys/module/uv2800/parameters/adsp_debug
 * ------------------------------------------------------------------ */
static bool uv_adsp_debug;
module_param_named(adsp_debug, uv_adsp_debug, bool, 0644);
MODULE_PARM_DESC(adsp_debug, "1 = print adsp_read diagnostics to dmesg (default 0)");

/* --- adsp_read：直读 ADSP 里保存的 deep_term_volt 原值 ---
 * 实测（独立审计 §3c.1）：走 getter 的"字段重读"返回路径，天然绕过 ③ 的强制，
 * 因此读到的是硬件真值，不受 uv_adsp_mv 影响。
 * 不要用 adsp_read 的读数判断 ③ 是否生效（那要用驱动投票日志）。*/
static noinline __attribute__((no_sanitize("kcfi")))
int uv_call_getter(void *dev, int *out, void *fn)
{
	int (*f)(void *, int *) = fn;
	return f(dev, out);
}

static int uv_adsp_read_set(const char *val, const struct kernel_param *kp)
{
	void *dev, *fn;
	int out = 0, rc;

	/* 失败时清除上次读数，兼容仍采用“写触发 + cat”协议的用户态。 */
	uv_adsp_raw = 0;
	if (!smp_load_acquire(&uv_adsp_ready))
		return -EOPNOTSUPP;
	dev = READ_ONCE(uv_dev);
	fn = uv_get_addr;
	if (!fn || !dev)
		return -EAGAIN;
	WRITE_ONCE(uv_read_task, current);
	rc = uv_call_getter(dev, &out, fn);
	WRITE_ONCE(uv_read_task, NULL);
	if (uv_adsp_debug)
		pr_info("uv2800: 直读 ADSP deep_term_volt = %d mV (rc=%d)\n", out, rc);
	if (rc)
		return rc < 0 ? rc : -EIO;
	uv_adsp_raw = out;
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

/* ================= hooks ================= */
static int uv_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_get = {
	.symbol_name = "oplus_comm_update_vbat_uv_thr",
	.offset = 0x30,
	.pre_handler = uv_get,
};
static int uv_get(struct kprobe *p, struct pt_regs *regs)
{
	if (smp_load_acquire(&uv_hooks_ready) && !READ_ONCE(uv_bypass))
		regs->regs[8] = READ_ONCE(uv_target_mv);
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
	if (smp_load_acquire(&uv_hooks_ready) && !READ_ONCE(uv_bypass))
		regs->regs[8] = READ_ONCE(uv_target_mv);
	return 0;
}

/* getter 内部挂钩点（get_off 偏移 = "str w<get_reg>,[...]" 指令所在）。
 * 驱动读到的 ADSP term 在即将存回结构体前被强制为 uv_adsp_mv（默认 2540）。
 * 这个读值会进入驱动关机票计算：
 *     shutdown = (TARGET_SHUTDOWN - TARGET_TERM) + getter 读回值
 * （实测：读回 2540 -> shutdown 票 3200），因此 ③ 决定驱动侧关机电压。
 * 必须在 get_off 处改：该偏移之前的指令会刷新目标寄存器，入口改值会被覆盖。*/
static int uv_term_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_get = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.pre_handler = uv_term_get,
};
static int uv_term_get(struct kprobe *p, struct pt_regs *regs)
{
	if (smp_load_acquire(&uv_hooks_ready) && !READ_ONCE(uv_bypass) &&
	    READ_ONCE(uv_read_task) != current)
		regs->regs[cur_get_reg] = READ_ONCE(uv_adsp_mv);
	return 0;
}

/* getter 入口（offset 0）：捕获 dev 指针（三个 ColorOS 版本入口都是 x0 = dev），
 * 供 adsp_read / adsp_write 回写时复用同一个 dev。*/
static int uv_term_entry(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_entry = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.offset = 0,
	.pre_handler = uv_term_entry,
};
static int uv_term_entry(struct kprobe *p, struct pt_regs *regs)
{
	WRITE_ONCE(uv_dev, (void *)regs->regs[0]);
	return 0;
}

/* ================= 无需 vote 的 uv_dev 捕获 =================
 * 【背景】光靠 oplus_fg_get_deep_term_volt 入口捕获不够：该函数
 *   只在驱动 vote（插拔充电器）时被调用 -> 越狱/硬重启后必须插拔一次才能回写 ADSP。
 * 【实测发现】oplus_fg_set_batt_deep_dischg_count 入口的 x0 与 getter 需要的
 *   device 【完全相同】（本机 C16 实测：两者都是同一个指针），而它可被
 *   userspace 稳定触发：
 *       echo <当前值> > /sys/devices/virtual/oplus_chg/common/deep_dischg_counts
 *   （同值写入语义无变化，仅触发驱动调用）
 * 【安全性】本 hook 只读寄存器、不调用任何内核函数 -> 零崩溃风险；
 *   注册失败（如某些版本无此符号）则静默降级回"插拔捕获"路径。
 * 【注意】只在 uv_dev 为空时补写，绝不覆盖已捕获的指针。*/
static int uv_ddrc_entry(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_ddrc = {
	.symbol_name = "oplus_fg_set_batt_deep_dischg_count",
	.offset = 0,
	.pre_handler = uv_ddrc_entry,
};
static int uv_ddrc_entry(struct kprobe *p, struct pt_regs *regs)
{
	if (!READ_ONCE(uv_dev)) {
		WRITE_ONCE(uv_dev, (void *)regs->regs[0]);
		pr_info("uv2800: 从 deep_dischg 入口捕获 device\n");
	}
	return 0;
}

/* setter 内部挂钩点（set_off 偏移）：驱动发起纠偏写回时，把写入值统一成
 * uv_adsp_mv（默认 2540）—— 没有它，驱动会把 ADSP 打回它自己算出的 3250。
 * 平时驱动不做"vote 目标 != 当前 ADSP"的写入，④ 因此不活跃；一旦驱动纠偏
 * 就会执行（独立审计 §3c.3）。*/
static int uv_term_set(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_set = {
	.symbol_name = "oplus_fg_set_deep_term_volt",
	.pre_handler = uv_term_set,
};
static int uv_term_set(struct kprobe *p, struct pt_regs *regs)
{
	if (smp_load_acquire(&uv_hooks_ready) && !READ_ONCE(uv_bypass) &&
	    READ_ONCE(uv_write_task) != current)
		regs->regs[cur_set_reg] = READ_ONCE(uv_adsp_mv);
	return 0;
}

/* 只记录成功注册的探针；失败的 register_kprobe 也可能填写 addr，
 * 因此不能把 addr 非空当作已注册。失败回滚和卸载共用逆序清理。 */
static struct kprobe *uv_registered[6];
static unsigned int uv_registered_count;

static int uv_register_probe(struct kprobe *probe)
{
	int ret = register_kprobe(probe);

	if (ret) {
		pr_err("uv2800: 注册 %s+%#x 失败 (%d)\n",
		       probe->symbol_name, probe->offset, ret);
		return ret;
	}
	uv_registered[uv_registered_count++] = probe;
	return 0;
}

static void uv_unregister_all(void)
{
	WRITE_ONCE(uv_hooks_ready, false);
	WRITE_ONCE(uv_adsp_ready, false);
	while (uv_registered_count)
		unregister_kprobe(uv_registered[--uv_registered_count]);
	/* exit 先于参数 sysfs 删除：保留初始化后只读的调用地址，使已经
	 * 通过 ready 检查的回调可完成。后续 sysfs teardown 排空回调后才
	 * 释放模块内存；exit 本身不等待 ADSP I/O。 */
}

static int uv_resolve_addr(const char *sym, void **addr)
{
	struct kprobe probe = { .symbol_name = sym };
	int ret = register_kprobe(&probe);

	if (ret)
		return ret;
	*addr = (void *)probe.addr;
	unregister_kprobe(&probe);
	return 0;
}

static int __init uv2800_init(void)
{
	int ret;

	pr_info("uv2800: v11.0 init (vbat_uv=%d mV, adsp=%d mV)\n",
		uv_target_mv, uv_adsp_mv);

	ret = uv_verify_display();
	if (ret)
		return ret;

	ret = uv_detect_profile();
	if (ret) {
		pr_warn("uv2800: 未匹配到 profile -- 只注册显示 hook，ADSP 接口关闭\n");
	} else {
		/* 只有 ABI 验证通过才解析可调用地址和捕获 dev。 */
		ret = uv_resolve_addr("oplus_fg_get_deep_term_volt", &uv_get_addr);
		if (ret)
			goto fail;
		ret = uv_resolve_addr("oplus_fg_set_deep_term_volt", &uv_set_addr);
		if (ret)
			goto fail;
		kp_term_get.offset = uv_profiles[cur_profile_idx].get_off;
		kp_term_set.offset = uv_profiles[cur_profile_idx].set_off;

		ret = uv_register_probe(&kp_term_get);
		if (ret)
			goto fail;
		ret = uv_register_probe(&kp_term_set);
		if (ret)
			goto fail;
		ret = uv_register_probe(&kp_term_entry);
		if (ret)
			goto fail;
	}

	ret = uv_register_probe(&kp_get);
	if (ret)
		goto fail;
	ret = uv_register_probe(&kp_show);
	if (ret)
		goto fail;

	/* 无需 vote 的捕获为可选能力；未知 profile 不注册任何 ADSP 探针。 */
	if (cur_profile_idx >= 0) {
		if (uv_register_probe(&kp_ddrc))
			pr_warn("uv2800: deep_dischg 捕获不可用，回退到插拔捕获\n");
		smp_store_release(&uv_adsp_ready, true);
	}
	smp_store_release(&uv_hooks_ready, true);

	pr_info("uv2800: v11 ready, %u 个 hook, profile=[%s], vbat_uv=%d adsp=%d\n",
		uv_registered_count, cur_profile, uv_target_mv, uv_adsp_mv);
	return 0;

fail:
	uv_unregister_all();
	/* 失败路径从未发布 ADSP ready，没有已进入的自身 I/O。 */
	WRITE_ONCE(uv_dev, NULL);
	uv_get_addr = NULL;
	uv_set_addr = NULL;
	return ret;
}

static void __exit uv2800_exit(void)
{
	uv_unregister_all();
	pr_info("uv2800: unloaded\n");
}

module_init(uv2800_init);
module_exit(uv2800_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OnePlus 13: native SOC calibration via deep_term_volt, cross ColorOS 15/16/17");
