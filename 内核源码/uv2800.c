// uv2800.c —— 原生 SOC 校准方案（关机电压自定义 + ADSP 自动派生）
//
// ============ 功能总览 ============
//  ① uv_get ：挂钩 oplus_comm_update_vbat_uv_thr，把驱动算出的关机电压
//             vbat_uv 强制为运行时参数 uv_target_mv（默认 2800，即用户可调的
//             AP 关机电压 V_s）。
//  ② uv_show：挂钩 vbat_uv_show（sysfs 读出侧），同样返回 uv_target_mv ——
//             驱动内部值与状态栏读到的值必须一致。
//  ③ uv_term_get：挂钩 getter 内部 get_off，把驱动从 ADSP 读到的终止电压
//             （空电点）强制为 uv_term_mv（QBG 学习 term）。
//  ④ uv_term_set：挂钩 setter 内部 set_off，驱动纠偏写回时把写入值统一为
//             uv_term_mv（QBG 学习 term）。
//  uv_term_entry：在 getter 入口（offset 0）捕获 dev 指针（uv_dev），
//             供 adsp_read / adsp_write 复用同一个 dev。
//  uv_ddrc_entry：在 deep_dischg 入口补捕获 uv_dev，不依赖驱动 vote（插拔）。
//
//  用户态入口（module param）：
//    uv_target_mv  关机电压强制值（2000~5000 钳制，默认 2800）
//    uv_term_mv    QBG 学习 term；uv_adsp_mv 为兼容别名
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
//   · 关机 votable 锁定为 V_s；QBG 学习 term 由 uv_term_mv 独立控制；
//     C16/17 四票分离，C15 两票 + 原厂 2800 地板。
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
static int uv_target_mv = UV_TARGET_MV;   /* AP shutdown V_s */
static int uv_term_mv = 2540;              /* QBG learning term T */
static int uv_adsp_mv = 2540;              /* legacy alias of term */
static int uv_shutdown_mv = UV_TARGET_MV;  /* explicit alias of shutdown */

/* 目标态：actual deep_term、GAUGE_TERM/TARGET_TERM、GAUGE_SHUTDOWN/TARGET_SHUTDOWN
 * term 锁到 uv_term_mv，shutdown 锁到 uv_target_mv；两者分离。 */
static void uv_override_apply(void);

/* v11 公式：ADSP term = 2*V_s - 3060（FLOOR=3060）。
 * 2800 -> 2540；2900 -> 2740；3000 -> 2940；3060 -> 3060。
 * 这是 V_s 的派生值，不再作为独立静态值。 */
static int uv_derive_term(int vs)
{
	int t = 2 * vs - 3060;

	if (t < 2000)
		t = 2000;
	if (t > 5000)
		t = 5000;
	return t;
}

/* uv_target_mv 范围钳制
 * 任意整数都会直接成为 vbat_uv，必须限制在合理范围内
 * （与 adsp_write 的 2000~5000 钳制一致）。*/
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

/* ------------------------------------------------------------------
 * uv_adsp_mv / uv_term_mv：兼容旧脚本的只读/派生 term。
 * 值由 uv_target_mv（V_s）通过 v11 公式动态计算，写入不再能独立覆盖。
 * ------------------------------------------------------------------ */
static int uv_adsp_mv_set(const char *val, const struct kernel_param *kp)
{
	int v;

	if (kstrtoint(val, 10, &v))
		return -EINVAL;
	/* 忽略外部值：term 必须跟随 V_s，避免 WebUI/旧脚本写成静态值。 */
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

static int uv_shutdown_mv_set(const char *val, const struct kernel_param *kp)
{
	int v;

	if (kstrtoint(val, 10, &v))
		return -EINVAL;
	if (v < 2000 || v > 5000) {
		pr_warn("uv2800: shutdown %d mV 超出范围 2000~5000，拒绝\n", v);
		return -EINVAL;
	}
	uv_shutdown_mv = v;
	uv_target_mv = v;
	uv_term_mv = uv_derive_term(v);
	uv_adsp_mv = uv_term_mv;
	uv_override_apply();
	return 0;
}

static int uv_shutdown_mv_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_target_mv);
}

static const struct kernel_param_ops uv_shutdown_mv_ops = {
	.set = uv_shutdown_mv_set,
	.get = uv_shutdown_mv_get,
};
module_param_cb(uv_shutdown_mv, &uv_shutdown_mv_ops, &uv_shutdown_mv, 0644);
MODULE_PARM_DESC(uv_shutdown_mv, "AP shutdown voltage V_s in mV (default 2800)");


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
static int uv_override_expected = 4;
static int cur_profile_idx = -1;
static const char *cur_profile = "none";

/* ============ 回写所需信息 ============ */
static void *uv_dev;          /* 从 getter 入口 x0（或 deep_dischg 入口）捕获 */
static void *uv_set_addr;     /* oplus_fg_set_deep_term_volt 地址 */
static int   uv_bypass;       /* 1 = 放行所有 hook（回写后进入恢复模式）*/
static int   uv_last_volt;    /* 最近一次回写的电压（只用于 get 显示）*/
static int   uv_self_write;   /* 1 = 本次 setter 调用来自模块自己，hook 放行 */
static int   uv_self_read;    /* 1 = 本次 getter 调用来自模块自己，hook 放行 */
static void *uv_get_addr;     /* oplus_fg_get_deep_term_volt 地址 */
static int   uv_adsp_raw;     /* 直读到的 ADSP 原值 */

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
		/* profile 1 = ColorOS 15，只有 GAUGE_TERM/GAUGE_SHUTDOWN 两票；profile 0 = C16/17 四票 */
		uv_override_expected = (i == 1) ? 2 : 4;
		pr_info("uv2800: 匹配 profile [%s]  getter+%#x setter+%#x ABI=%s\n",
			p->name, p->get_off, p->set_off,
			p->set_ptr ? "(dev,int*)" : "(dev,int)");
		return 0;
	}
	return -ENOENT;
}

/* ================= votable 强制（目标态核心） =================
 * 原厂四个 votable 都是 VOTE_MAX：
 *   GAUGE_TERM_VOLTAGE / TARGET_TERM_VOLTAGE
 *   GAUGE_SHUTDOWN_VOLTAGE / TARGET_SHUTDOWN_VOLTAGE
 * 普通 vote() 2800 会输给原厂 3200/3250；只有 vote_override 能压过。
 * 四个都强制为 uv_target_mv 后：
 *   term 票 = T，shutdown 票 = V_s，actual term = T
 *   adjusted = V_s - T + T = V_s
 * gauge 的 FCC/QMAX/SOC/mAh 仍按 QBG 学习窗口，满充/放空后收敛。
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

/* ================= A1 实验：调用 oplus_set_batt_true_fcc =================
 * 仅用于验证 SET_TRUE_FCC(0x4b8) 是否能让 QBG 重锚 FCC/RM。
 * 不在正常路径使用；写任意值触发一次，读回上次 rc。
 * oplus_set_batt_true_fcc(x0) 只使用 x0（gauge ic dev），内部固定 value=1。
 */
static int uv_true_fcc_rc;
static int uv_true_fcc_val;

static noinline __attribute__((no_sanitize("kcfi")))
int uv_call_true_fcc(void *dev, void *fn)
{
	int (*f)(void *) = fn;

	return f(dev);
}

static int uv_true_fcc_set(const char *val, const struct kernel_param *kp)
{
	void *fn = uv_kprobe_sym("oplus_set_batt_true_fcc");
	int rc;

	if (!fn) {
		pr_warn("uv2800: oplus_set_batt_true_fcc 符号不可用\n");
		return -ENOENT;
	}
	if (!uv_dev) {
		pr_warn("uv2800: uv_dev 未捕获，无法调用 true_fcc\n");
		return -EAGAIN;
	}
	rc = uv_call_true_fcc(uv_dev, fn);
	uv_true_fcc_rc = rc;
	pr_info("uv2800: true_fcc(0x4b8) rc=%d dev=%px\n", rc, uv_dev);
	return rc;
}

static int uv_true_fcc_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_true_fcc_rc);
}

static const struct kernel_param_ops uv_true_fcc_ops = {
	.set = uv_true_fcc_set,
	.get = uv_true_fcc_get,
};
module_param_cb(uv_true_fcc, &uv_true_fcc_ops, &uv_true_fcc_val, 0644);
MODULE_PARM_DESC(uv_true_fcc, "A1 test: write any value to call oplus_set_batt_true_fcc once");

static int uv_true_fcc_vg_rc;
static int uv_true_fcc_vg_val;

static int uv_true_fcc_vg_set(const char *val, const struct kernel_param *kp)
{
	void *fn = uv_kprobe_sym("oplus_chg_vg_set_true_fcc");
	int rc;

	if (!fn) {
		pr_warn("uv2800: oplus_chg_vg_set_true_fcc 符号不可用\n");
		return -ENOENT;
	}
	if (!uv_dev) {
		pr_warn("uv2800: uv_dev 未捕获，无法调用 true_fcc_vg\n");
		return -EAGAIN;
	}
	rc = uv_call_true_fcc(uv_dev, fn);
	uv_true_fcc_vg_rc = rc;
	pr_info("uv2800: true_fcc_vg(0x4b8 wrapper) rc=%d dev=%px\n", rc, uv_dev);
	return rc;
}

static int uv_true_fcc_vg_get(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_true_fcc_vg_rc);
}

static const struct kernel_param_ops uv_true_fcc_vg_ops = {
	.set = uv_true_fcc_vg_set,
	.get = uv_true_fcc_vg_get,
};
module_param_cb(uv_true_fcc_vg, &uv_true_fcc_vg_ops, &uv_true_fcc_vg_val, 0644);
MODULE_PARM_DESC(uv_true_fcc_vg, "A1 test: write any value to call oplus_chg_vg_set_true_fcc once");

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
	uv_bypass = v ? 0 : 1;

	if (v)
		pr_info("uv2800: resume=1，已退出恢复模式，所有 hook 重新生效\n");
	else
		pr_info("uv2800: resume=0，已进入恢复模式，所有 hook 放行\n");
	return 0;
}

/* 读：直接反映 uv_bypass，避免与 uv_resume_val 不一致 */
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
		/* 关键：告诉 setter hook「这次是模块自己发的」，否则会被强制成 2800 */
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
	int out = 0, rc;

	if (uv_get_addr && uv_dev) {
		uv_self_read = 1;
		rc = uv_call_getter(uv_dev, &out, uv_get_addr);
		uv_self_read = 0;
		uv_adsp_raw = out;
		if (uv_adsp_debug)
			pr_info("uv2800: 直读 ADSP deep_term_volt = %d mV (rc=%d)\n", out, rc);
	} else {
		/* 默认静默：轮询期间这里最多被调用 10 次（service.sh 探测循环）。
		 * 不打印内核地址（uv_dev / uv_get_addr），避免无意义信息泄漏。 */
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

/* getter 内部挂钩点（get_off 偏移 = "str w<get_reg>,[...]" 指令所在）。
 * 驱动读到的 ADSP term 在即将存回结构体前被强制为 uv_term_mv（T）。
 * 这个读值会进入驱动关机票计算：
 *     shutdown = (TARGET_SHUTDOWN - TARGET_TERM) + getter 读回值
 * C16/17 四票分离：target_term=T、shutdown=V_s，因此 adjusted=V_s；
 * C15 两票：target_term 是 DT 常量 3250，2800 由原厂 SPEC 地板兜底。
 * 必须在 get_off 处改：该偏移之前的指令会刷新目标寄存器，入口改值会被覆盖。*/
static int uv_term_get(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_get = {
	.symbol_name = "oplus_fg_get_deep_term_volt",
	.pre_handler = uv_term_get,
};
static int uv_term_get(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass && !uv_self_read)
		regs->regs[cur_get_reg] = uv_term_mv;	/* 学习 term 独立于 shutdown */
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
	uv_dev = (void *)regs->regs[0];
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
	if (!uv_dev) {
		uv_dev = (void *)regs->regs[0];
		pr_info("uv2800: 从 deep_dischg 入口捕获 device=%px\n", uv_dev);
	}
	return 0;
}

/* setter 内部挂钩点（set_off 偏移）：驱动发起纠偏写回时，把写入值统一成
 * uv_term_mv（T）—— 没有它，驱动会把 ADSP 打回它自己算出的 3250。
 * 平时驱动不做"vote 目标 != 当前 ADSP"的写入，④ 因此不活跃；一旦驱动纠偏
 * 就会执行（独立审计 §3c.3）。*/
static int uv_term_set(struct kprobe *p, struct pt_regs *regs);
static struct kprobe kp_term_set = {
	.symbol_name = "oplus_fg_set_deep_term_volt",
	.pre_handler = uv_term_set,
};
static int uv_term_set(struct kprobe *p, struct pt_regs *regs)
{
	if (!uv_bypass && !uv_self_write)
		regs->regs[cur_set_reg] = uv_term_mv;	/* 学习 term 独立于 shutdown */
	return 0;
}

static int __init uv2800_init(void)
{
	int ret, n = 0;
	u32 tmp;

	pr_info("uv2800: v11.0 init (vbat_uv=%d mV, adsp=%d mV)\n",
		uv_target_mv, uv_adsp_mv);

	ret = uv_verify_display();
	if (ret)
		return ret;

	/* 取 getter 地址（直读用）*/
	if (!uv_read_word("oplus_fg_get_deep_term_volt", 0, &tmp)) {
		kp_verify.symbol_name = "oplus_fg_get_deep_term_volt";
		kp_verify.addr = NULL;
		if (!register_kprobe(&kp_verify)) {
			uv_get_addr = (void *)kp_verify.addr;
			unregister_kprobe(&kp_verify);
			kp_verify.addr = NULL;
			kp_verify.symbol_name = NULL;
		}
	}

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

	/* 无需 vote 的 uv_dev 捕获（best-effort，失败不影响主体功能）*/
	if (!register_kprobe(&kp_ddrc)) n++;
	else pr_warn("uv2800: kp_ddrc 注册失败（deep_dischg 入口），回退到插拔捕获\n");

	/* 目标态：term 票锁 T，shutdown 票锁 V_s，actual term=T。
	 * votable 尚未创建时，由 service.sh 写 uv_apply 重放。*/
	uv_override_apply();
	if (!uv_override_ok)
		pr_info("uv2800: votable 尚未就绪，等待 service.sh 写 uv_apply\n");

	pr_info("uv2800: v11 ready, %d 个 hook, profile=[%s], vbat_uv=%d adsp=%d\n",
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
