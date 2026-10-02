// uv2800.c  (v10) —— v9 + UI SOC 电压重映射（仅 COS17）
//
// v10 新增 SOC 修正：
//   问题：库仑计的空电点在 ~3250mV，但模块把关机电压降到 2800mV，
//         导致最后 450mV 一直显示 0~1%。
//   方案：hook bs_update_data 写入「输入 SOC」的两个位置（+0x178 / +0x1f8），
//         当电压落在 [soc_lo, soc_hi] 时，把 SOC 重映射为按电压线性下降。
//   电压来源：hook oplus_mms_get_item_data 的 post_handler，
//             缓存 item_id==2（电池电压 mV）。
//   注意：bs_update_data 只存在于 COS16/17，且内部结构不同，
//         当前只对 COS17 启用（签名不匹配则自动跳过）。
//
// uv2800.c  (v9)  —— 跨 ColorOS 15/16/17 + 双回写入口
//
// v9 在 v8 基础上新增 adsp_write 参数，用于【方案3 验证】：
//   restore    : 写电压 + 置 uv_bypass=1（恢复原值流程，之后所有 hook 放行）
//   adsp_write : 只写电压，【不改变】uv_bypass（探测/验证用，强制仍然生效）
//
// 为什么需要 adsp_write：
//   验证「把 2800 真正写进电量计后，SOC 会不会重新锚定」时，
//   必须保持模块仍在强制 2800（否则关机电压会跟着变），
//   而 restore 会把 uv_bypass 置 1 → 强制停止 → 测试条件被破坏。
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

static void *uv_dev;
static void *uv_set_addr;
static int   uv_bypass;
static int   uv_last_volt;

/* ============ v10: UI SOC 修正 ============ */
static int soc_fix;                 /* 1 = 启用 SOC 电压重映射 */
module_param(soc_fix, int, 0644);
MODULE_PARM_DESC(soc_fix, "1 = enable UI SOC voltage remap (COS17 only)");

static int soc_lo = 2800;           /* 重映射下界 mV（对应 0%）*/
module_param(soc_lo, int, 0644);
static int soc_hi = 3250;           /* 重映射上界 mV（对应 soc_top）*/
module_param(soc_hi, int, 0644);
static int soc_top = 500;           /* 上界对应的 SOC（x100，500=5%）*/
module_param(soc_top, int, 0644);

static int uv_batt_mv;                 /* 缓存的电池电压 mV */
static int uv_batt_ma;                 /* 缓存的电流 mA */
static int soc_cur_max = 500;          /* 电流超过此值(mA)时跳过修正 */
module_param(soc_cur_max, int, 0644);

/* 只读调试参数 */
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

static int uv_batt_mv_show(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_batt_mv);
}
static int uv_batt_ma_show(char *buf, const struct kernel_param *kp)
{
	return uv_itoa(buf, uv_batt_ma);
}
static const struct kernel_param_ops uv_mv_ops = { .get = uv_batt_mv_show };
static const struct kernel_param_ops uv_ma_ops = { .get = uv_batt_ma_show };
module_param_cb(batt_mv, &uv_mv_ops, NULL, 0444);
module_param_cb(batt_ma, &uv_ma_ops, NULL, 0444);


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

/* bypass_flag: 1 = 写完后置 uv_bypass（restore 语义）；0 = 不影响强制（探测语义）*/
static int uv_write_adsp(int volt, int bypass_flag)
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

	if (bypass_flag)
		uv_bypass = 1;

	pr_info("uv2800: [%s] 写 %d mV -> oplus_fg_set_deep_term_volt(%px) ABI=%s\n",
		bypass_flag ? "restore" : "adsp_write", volt, uv_set_addr,
		cur_set_ptr ? "(dev,int*)" : "(dev,int)");

	if (cur_set_ptr)
		rc = uv_call_setter_ptr(uv_dev, &volt, uv_set_addr);
	else
		rc = uv_call_setter_val(uv_dev, volt, uv_set_addr);

	uv_last_volt = volt;
	pr_info("uv2800: 写入返回 %d%s\n", rc,
		bypass_flag ? "，已进入恢复模式（所有 hook 放行）" : "（强制仍生效）");
	return rc;
}

/* --- restore：写电压 + 置 bypass --- */
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
		uv_write_adsp(v, 1);
	else if (v != 0)
		pr_warn("uv2800: restore 写入 %d 不是有效电压（应写 2000~5000）\n", v);

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
MODULE_PARM_DESC(restore, "write voltage + enter restore mode (all hooks bypass)");

/* --- adsp_write：只写电压，不影响强制 --- */
static int uv_adsp_write_val;

static int uv_adsp_write_set(const char *val, const struct kernel_param *kp)
{
	int v = 0, i, neg = 0;

	for (i = 0; val[i] == ' '; i++)
		;
	if (val[i] == '-') { neg = 1; i++; }
	for (; val[i] >= '0' && val[i] <= '9'; i++)
		v = v * 10 + (val[i] - '0');
	if (neg)
		v = -v;

	uv_adsp_write_val = v;

	if (v >= 2000 && v <= 5000)
		uv_write_adsp(v, 0);
	else if (v != 0)
		pr_warn("uv2800: adsp_write 写入 %d 不是有效电压（应写 2000~5000）\n", v);

	return 0;
}

static const struct kernel_param_ops uv_adsp_write_ops = {
	.set = uv_adsp_write_set,
	.get = uv_restore_get,
};
module_param_cb(adsp_write, &uv_adsp_write_ops, &uv_adsp_write_val, 0644);
MODULE_PARM_DESC(adsp_write, "write voltage to ADSP without changing force state");

/* ================= v10: SOC 修正 ================= */
/*
 * post_handler 在 oplus_mms_get_item_data 返回后执行，
 * regs 仍是入口时的寄存器快照，所以 x1=item_id、x2=buf 都有效，
 * 而 buf 此时已被函数填好 —— 这是读取返回值的标准做法。
 */
/*
 * 重要：kprobe 的 post_handler 不是「函数返回后」，而是「单步执行完
 * 被替换的那条指令后」—— 即函数刚入口就触发，此时 buf 还没被填充。
 * 所以这里用 per-CPU 保存「上一次」的 (item, buf)，在下一次调用入口
 * 读取它 —— 那时上一次的 buf 已经被填好了。延迟一次调用完全可接受。
 */
/* 用 kretprobe：只有它能在函数【返回后】读取，拿到正确配对的 (item, buf) */
static int uv_mms_ent(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	u32 item = (u32)regs->regs[1];
	void *buf = (void *)regs->regs[2];

	*(u32 *)ri->data = item;
	*(void **)(ri->data + 8) = buf;
	return 0;
}

static int uv_mms_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	u32 item = *(u32 *)ri->data;
	void *buf = *(void **)(ri->data + 8);

	if (!buf)
		return 0;

	if (item == 2) {                    /* 电池电压 mV */
		int v = *(int *)buf;
		if (v > 2000 && v < 5000)
			uv_batt_mv = v;
	} else if (item == 0x25) {          /* 电流 mA（有符号）*/
		int c = *(int *)buf;
		if (c > -20000 && c < 20000)
			uv_batt_ma = c;
	}
	return 0;
}

static struct kretprobe krp_mms = {
	.kp.symbol_name = "oplus_mms_get_item_data",
	.entry_handler = uv_mms_ent,
	.handler = uv_mms_ret,
	.data_size = 16,
	.maxactive = 64,
};

/*
 * 改写「输入 SOC」写入值。
 * bs_update_data 里有两处 str w8,[x19,#0x38]（+0x178 / +0x1f8），
 * 都在写入前被这里拦截。
 */
static int uv_soc_pre(struct kprobe *p, struct pt_regs *regs)
{
	int soc = (int)regs->regs[8];
	int v = uv_batt_mv;
	int lo = soc_lo, hi = soc_hi, top = soc_top;
	int mapped;

	if (!soc_fix || hi <= lo || top <= 0)
		return 0;
	if (v < lo || v >= hi)
		return 0;
	/* 大电流充电时端电压明显偏高，跳过修正；小电流不阻止 */
	if (uv_batt_ma > soc_cur_max)
		return 0;

	mapped = (v - lo) * top / (hi - lo);
	if (mapped > top)
		mapped = top;
	if (soc < mapped)
		regs->regs[8] = mapped;         /* 只抬高，不压低 */
	return 0;
}

static struct kprobe kp_soc_a = {
	.symbol_name = "bs_update_data",
	.offset = 0x178,
	.pre_handler = uv_soc_pre,
};
static struct kprobe kp_soc_b = {
	.symbol_name = "bs_update_data",
	.offset = 0x1f8,
	.pre_handler = uv_soc_pre,
};

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

/* 额外的 dev 捕获点：这三个函数的 x0 都是同一个 gauge dev
 *  - oplus_fg_set_batt_deep_dischg_count : 可通过写 deep_dischg_counts（相同值）触发
 *  - oplus_fg_get_batt_deep_dischg_count : 开机/事件时调用
 *  - oplus_fg_set_deep_term_volt        : 深度放电事件时调用
 * 目的：热替换模块后不需要重启也能拿到 dev
 */
static int uv_cap_dev(struct kprobe *p, struct pt_regs *regs)
{
	if (regs->regs[0])
		uv_dev = (void *)regs->regs[0];
	return 0;
}

static struct kprobe kp_cap_setcnt = {
	.symbol_name = "oplus_fg_set_batt_deep_dischg_count",
	.offset = 0,
	.pre_handler = uv_cap_dev,
};
static struct kprobe kp_cap_getcnt = {
	.symbol_name = "oplus_fg_get_batt_deep_dischg_count",
	.offset = 0,
	.pre_handler = uv_cap_dev,
};
static struct kprobe kp_cap_setterm = {
	.symbol_name = "oplus_fg_set_deep_term_volt",
	.offset = 0,
	.pre_handler = uv_cap_dev,
};

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

	pr_info("uv2800: v10 init (target %d mV)\n", UV_TARGET_MV);

	ret = uv_verify_display();
	if (ret)
		return ret;

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
		if (!register_kprobe(&kp_cap_setcnt)) n++;
		else pr_warn("uv2800: kp_cap_setcnt 注册失败");
		if (!register_kprobe(&kp_cap_getcnt)) n++;
		else pr_warn("uv2800: kp_cap_getcnt 注册失败");
		if (!register_kprobe(&kp_cap_setterm)) n++;
		else pr_warn("uv2800: kp_cap_setterm 注册失败");
	}

	if (!register_kprobe(&kp_get)) n++;
	else { pr_err("uv2800: kp_get 失败\n"); return -EIO; }
	if (!register_kprobe(&kp_show)) n++;
	else { pr_err("uv2800: kp_show 失败\n"); return -EIO; }

	/* v10: SOC 修正（仅 COS17，签名校验通过才注册）*/
	if (!uv_read_word("bs_update_data", 0x178, &tmp) && tmp == 0xb9003a68) {
		if (!register_kprobe(&kp_soc_a)) n++;
		else pr_warn("uv2800: kp_soc_a 注册失败\n");
		if (!uv_read_word("bs_update_data", 0x1f8, &tmp) && tmp == 0xb9003a68) {
			if (!register_kprobe(&kp_soc_b)) n++;
			else pr_warn("uv2800: kp_soc_b 注册失败\n");
		}
		if (!register_kretprobe(&krp_mms)) n++;
		else pr_warn("uv2800: krp_mms 注册失败\n");
		pr_info("uv2800: SOC 修正已注册（soc_fix=%d, %d~%dmV -> 0~%d）\n",
			soc_fix, soc_lo, soc_hi, soc_top);
	} else {
		pr_warn("uv2800: bs_update_data 签名不匹配，跳过 SOC 修正\n");
	}

	pr_info("uv2800: v10 ready, %d 个 hook, profile=[%s], setter=%px\n",
		n, cur_profile, uv_set_addr);
	pr_info("uv2800: restore=写电压+停止强制 / adsp_write=只写电压 / soc_fix=SOC修正\n");
	return 0;
}

static void __exit uv2800_exit(void)
{
	if (kp_soc_b.addr)       unregister_kprobe(&kp_soc_b);
	if (kp_soc_a.addr)       unregister_kprobe(&kp_soc_a);
	unregister_kretprobe(&krp_mms);
	if (kp_cap_setterm.addr) unregister_kprobe(&kp_cap_setterm);
	if (kp_cap_getcnt.addr)  unregister_kprobe(&kp_cap_getcnt);
	if (kp_cap_setcnt.addr)  unregister_kprobe(&kp_cap_setcnt);
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
MODULE_DESCRIPTION("OnePlus 13: deep term voltage 2800mV, cross ColorOS 15/16/17, dual writeback");
