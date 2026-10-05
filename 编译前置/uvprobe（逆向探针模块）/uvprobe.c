// uvprobe.c v4 —— 判定 uv_term_set 语义错误的决定性探针
//   set_term : 挂在 oplus_fg_set_deep_term_volt 【入口 offset 0】
//              → 读到的是【驱动原始传入】的 x1（模块的 hook 在内部 0x34，晚于这里）
//   vote_cb  : oplus_gauge_term_voltage_vote_callback —— 确认 vote 是否真的触发
//   get_ddrc : oplus_gauge_get_ddrc_status —— vote 值来源（按 count 查 DT 表）
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/types.h>
#include <linux/kernel.h>

static int p_set_term(struct kprobe *p, struct pt_regs *regs)
{
	pr_info("uvprobe: SET_deep_term_volt   x0=%px x1=%ld (%#lx)\n",
		(void *)regs->regs[0], (long)regs->regs[1], (unsigned long)regs->regs[1]);
	return 0;
}
static int p_vote_cb(struct kprobe *p, struct pt_regs *regs)
{
	pr_info("uvprobe: term_voltage_vote_cb x0=%px x1=%px x2=%px\n",
		(void *)regs->regs[0], (void *)regs->regs[1], (void *)regs->regs[2]);
	return 0;
}
static int p_get_ddrc(struct kprobe *p, struct pt_regs *regs)
{
	pr_info("uvprobe: gauge_get_ddrc_status x0=%px x1=%px\n",
		(void *)regs->regs[0], (void *)regs->regs[1]);
	return 0;
}

static struct kprobe kp1 = { .symbol_name = "oplus_fg_set_deep_term_volt", .pre_handler = p_set_term };
static struct kprobe kp2 = { .symbol_name = "oplus_gauge_term_voltage_vote_callback", .pre_handler = p_vote_cb };
static struct kprobe kp3 = { .symbol_name = "oplus_gauge_get_ddrc_status", .pre_handler = p_get_ddrc };
static struct kprobe *all[] = { &kp1, &kp2, &kp3 };

static int __init uvprobe_init(void)
{
	int i;
	for (i = 0; i < ARRAY_SIZE(all); i++) {
		int r = register_kprobe(all[i]);
		if (r) { pr_info("uvprobe: FAIL %s\n", all[i]->symbol_name); all[i]->addr = NULL; }
		else pr_info("uvprobe: OK %s\n", all[i]->symbol_name);
	}
	return 0;
}
static void __exit uvprobe_exit(void)
{
	int i;
	for (i = 0; i < ARRAY_SIZE(all); i++)
		if (all[i]->addr) unregister_kprobe(all[i]);
	pr_info("uvprobe: unloaded\n");
}
module_init(uvprobe_init);
module_exit(uvprobe_exit);
MODULE_LICENSE("GPL");
