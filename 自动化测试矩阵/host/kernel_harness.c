/* Host fault injection for the actual uv2800.c; Linux/ADSP calls are stubs.
 * test_kernel.py inserts the source at UV2800_SOURCE and builds a temp binary. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint32_t u32;
typedef uint8_t u8;
struct task_struct { int id; };
struct pt_regs { uintptr_t regs[31]; };
struct kprobe {
    const char *symbol_name;
    void *addr;
    unsigned int offset;
    int (*pre_handler)(struct kprobe *, struct pt_regs *);
};
struct kernel_param { void *arg; };
struct kernel_param_ops {
    int (*set)(const char *, const struct kernel_param *);
    int (*get)(char *, const struct kernel_param *);
};
static struct task_struct task_a = {1}, task_b = {2};
static struct task_struct *fake_current = &task_a;
#define current fake_current
static void maybe_exit(const char *field);
#define READ_ONCE(x) (*(volatile __typeof__(x) *)&(x))
#define WRITE_ONCE(x, v) (maybe_exit(#x), READ_ONCE(x) = (v))
/* Single-threaded scheduling injection below tests ordering of calls, not the
 * actual ARM64 acquire/release implementation. */
#define smp_load_acquire(p) READ_ONCE(*(p))
#define smp_store_release(p, v) WRITE_ONCE(*(p), (v))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define noinline __attribute__((noinline))
#define __init
#define __exit
#define pr_warn(...) ((void)0)
#define pr_err(...) ((void)0)
#define pr_info(...) ((void)0)
#define module_param(...)
#define module_param_cb(...)
#define module_param_named(...)
#define MODULE_PARM_DESC(...)
#define MODULE_LICENSE(...)
#define MODULE_DESCRIPTION(...)
#define module_init(...)
#define module_exit(...)
static int register_kprobe(struct kprobe *p);
static void unregister_kprobe(struct kprobe *p);
static int kstrtoint(const char *s, int base, int *out)
{
    char *end;
    long value;
    errno = 0;
    value = strtol(s, &end, base);
    if (errno || end == s || (*end && strcmp(end, "\n")) ||
        value < INT32_MIN || value > INT32_MAX)
        return -EINVAL;
    *out = (int)value;
    return 0;
}

/* UV2800_SOURCE */

static u32 code_update[128], code_show[128], code_get[128], code_set[128], code_count[128];
static struct kprobe *fail_probe, *active[16], *permanent[6];
static int active_count, permanent_count, calls, vendor_rc;
static int get_calls, set_calls, seen_volt;
static bool fail_resolve;
static bool exit_at_call;

static void maybe_exit(const char *field)
{
    if (exit_at_call && (!strcmp(field, "uv_write_task") || !strcmp(field, "uv_read_task"))) {
        exit_at_call = false;
        uv2800_exit();
        assert(!active_count && !uv_adsp_ready && !uv_hooks_ready);
        assert(uv_get_addr && uv_set_addr); /* valid until sysfs callbacks drain */
    }
}

static int register_kprobe(struct kprobe *p)
{
    u32 *base = NULL;
    if (!strcmp(p->symbol_name, "oplus_comm_update_vbat_uv_thr")) base = code_update;
    if (!strcmp(p->symbol_name, "vbat_uv_show")) base = code_show;
    if (!strcmp(p->symbol_name, "oplus_fg_get_deep_term_volt")) base = code_get;
    if (!strcmp(p->symbol_name, "oplus_fg_set_deep_term_volt")) base = code_set;
    if (!strcmp(p->symbol_name, "oplus_fg_set_batt_deep_dischg_count")) base = code_count;
    assert(base);
    p->addr = (u8 *)base + p->offset; /* failed registration may still set addr */
    if (p == fail_probe || (fail_resolve && p != &kp_verify && !p->pre_handler))
        return -EIO;
    assert(active_count < 16);
    active[active_count++] = p;
    if (p->pre_handler) {
        struct pt_regs regs = {{0}};
        int i;
        assert(permanent_count < 6);
        permanent[permanent_count++] = p;
        /* Never mutate a driver's registers during partial initialization. */
        if (p == &kp_get || p == &kp_show || p == &kp_term_get || p == &kp_term_set) {
            for (i = 0; i < 31; i++) regs.regs[i] = 4000;
            p->pre_handler(p, &regs);
            for (i = 0; i < 31; i++) assert(regs.regs[i] == 4000);
        }
    }
    return 0;
}

static void unregister_kprobe(struct kprobe *p)
{
    int i;
    for (i = 0; i < active_count && active[i] != p; i++) {}
    assert(i < active_count); /* catches unregister of failed/unregistered probe */
    active[i] = active[--active_count];
    if (p->pre_handler) {
        assert(permanent_count > 0 && permanent[permanent_count - 1] == p);
        permanent_count--;
    }
}

static void reset(int profile)
{
    assert(active_count == 0 && permanent_count == 0);
    memset(code_update, 0, sizeof(code_update));
    memset(code_show, 0, sizeof(code_show));
    memset(code_get, 0, sizeof(code_get));
    memset(code_set, 0, sizeof(code_set));
    code_update[0x2c / 4] = 0xb9400108;
    code_update[0x30 / 4] = 0xb9000268;
    code_show[0x10 / 4] = 0xaa0203e0;
    code_show[0x20 / 4] = 0x2a0803e2;
    if (profile >= 0) {
        code_get[uv_profiles[profile].get_off / 4] = uv_profiles[profile].get_want;
        code_set[uv_profiles[profile].set_off / 4] = uv_profiles[profile].set_want;
    }
    cur_profile_idx = -1;
    cur_profile = "none";
    cur_get_reg = cur_set_reg = cur_set_ptr = 0;
    uv_registered_count = 0;
    uv_hooks_ready = uv_adsp_ready = false;
    uv_get_addr = uv_set_addr = uv_dev = NULL;
    uv_read_task = uv_write_task = NULL;
    uv_bypass = uv_last_volt = uv_adsp_raw = 0;
    uv_target_mv = 2800;
    uv_adsp_mv = 2540;
    fail_probe = NULL;
    fail_resolve = false;
    exit_at_call = false;
    calls = get_calls = set_calls = vendor_rc = seen_volt = 0;
    fake_current = &task_a;
}

static void check_self_isolation(bool write)
{
    struct pt_regs regs = {{0}};
    int reg = write ? cur_set_reg : cur_get_reg;
    regs.regs[reg] = 3250;
    if (write) uv_term_set(&kp_term_set, &regs);
    else uv_term_get(&kp_term_get, &regs);
    assert(regs.regs[reg] == 3250); /* own raw call bypasses */
    fake_current = &task_b;
    if (write) uv_term_set(&kp_term_set, &regs);
    else uv_term_get(&kp_term_get, &regs);
    assert(regs.regs[reg] == 2540); /* another task never inherits bypass */
    fake_current = &task_a;
}

static int vendor_get(void *dev, int *out)
{
    assert(dev == &task_a);
    calls++; get_calls++;
    if (uv_hooks_ready) check_self_isolation(false);
    /* 真机（C17/PJZ110）实测：getter 成功时返回电压本身（正数），失败才返回负 errno。 */
    *out = 3250;
    return vendor_rc < 0 ? vendor_rc : 3250;
}
static int vendor_set_val(void *dev, int value)
{
    assert(dev == &task_a);
    calls++; set_calls++;
    seen_volt = value;
    if (uv_hooks_ready) check_self_isolation(true);
    return vendor_rc;
}
static int vendor_set_ptr(void *dev, int *value)
{
    return vendor_set_val(dev, *value);
}
/* getter 失败路径的另一种形态：不写 out（保持 0）却返回正数。 */
static int vendor_get_zero(void *dev, int *out)
{
    (void)dev; (void)out;
    calls++; get_calls++;
    return 1;
}

static void test_registration(void)
{
    struct kprobe *required[] = {&kp_term_get, &kp_term_set, &kp_term_entry, &kp_get, &kp_show};
    unsigned int i;
    for (i = 0; i < ARRAY_SIZE(required); i++) {
        reset(0);
        fail_probe = required[i];
        assert(uv2800_init() == -EIO);
        assert(active_count == 0 && uv_registered_count == 0);
        assert(!uv_hooks_ready && !uv_adsp_ready && !uv_get_addr && !uv_set_addr);
    }
    reset(0);
    code_show[0x20 / 4] = 0;
    assert(uv2800_init() == -EINVAL && active_count == 0);
    reset(0);
    fail_resolve = true;
    assert(uv2800_init() == -EIO && active_count == 0);
    reset(0);
    fail_probe = &kp_ddrc;
    assert(uv2800_init() == 0 && uv_adsp_ready && uv_registered_count == 5);
    uv2800_exit();
    assert(active_count == 0);
    puts("PASS registration: all required failures roll back; optional probe may fail");
}

static void test_unknown_profile(void)
{
    struct pt_regs regs = {{0}};
    reset(-1);
    assert(uv2800_init() == 0 && uv_registered_count == 2 && !uv_adsp_ready);
    assert(!uv_get_addr && !uv_set_addr && !uv_dev);
    uv_show(&kp_show, &regs);
    assert(regs.regs[8] == 2800);
    /* Even stale/injected addresses never bypass the capability gate. */
    uv_dev = &task_a; uv_get_addr = vendor_get; uv_set_addr = vendor_set_val;
    assert(uv_adsp_write_set("3250", NULL) == -EOPNOTSUPP);
    uv_adsp_raw = 3250;
    assert(uv_adsp_read_set("1", NULL) == -EOPNOTSUPP && uv_adsp_raw == 0);
    assert(calls == 0);
    uv2800_exit();
    puts("PASS unknown profile: display only; zero ADSP calls");
}

static void test_adsp(int profile)
{
    reset(profile);
    assert(uv2800_init() == 0 && uv_registered_count == 6);
    assert(cur_profile_idx == profile);
    assert(uv_adsp_write_set("3250", NULL) == -EAGAIN);
    assert(uv_adsp_read_set("1", NULL) == -EAGAIN);
    uv_dev = &task_a;
    uv_get_addr = vendor_get;
    uv_set_addr = cur_set_ptr ? (void *)vendor_set_ptr : (void *)vendor_set_val;
    assert(uv_adsp_write_set("3250", NULL) == 0 && seen_volt == 3250);
    assert(uv_last_volt == 3250 && !uv_write_task);
    assert(uv_adsp_read_set("1", NULL) == 0 && uv_adsp_raw == 3250 && !uv_read_task);
    vendor_rc = -EIO;
    assert(uv_adsp_write_set("3300", NULL) == -EIO && uv_last_volt == 3250 && !uv_write_task);
    assert(uv_adsp_read_set("1", NULL) == -EIO && uv_adsp_raw == 0 && !uv_read_task);
    /* getter 无效读数（out 未写入保持 0，正返回值）也必须失败：物理区间兜底。 */
    vendor_rc = 0;
    assert(uv_adsp_read_set("1", NULL) == 0 && uv_adsp_raw == 3250);
    uv_get_addr = vendor_get_zero;
    assert(uv_adsp_read_set("1", NULL) == -EIO && uv_adsp_raw == 0);
    uv_get_addr = vendor_get;
    assert(uv_adsp_write_set("0", NULL) == -EINVAL);
    assert(uv_adsp_write_set("1999", NULL) == -EINVAL);
    assert(uv_adsp_write_set("5001", NULL) == -EINVAL);
    assert(uv_adsp_write_set("abc", NULL) == -EINVAL);
    uv2800_exit();
    assert(active_count == 0);
    printf("PASS ADSP profile %d: ABI dispatch, errors, stale reads, task isolation\n", profile);
}

static void test_exit_during_io(bool write)
{
    reset(0);
    assert(uv2800_init() == 0);
    uv_dev = &task_a;
    uv_get_addr = vendor_get;
    uv_set_addr = vendor_set_val;
    /* Simulate exit after capability/address checks but before the driver call.
     * The real sysfs teardown (after exit) waits for this callback to return. */
    exit_at_call = true;
    if (write) assert(uv_adsp_write_set("3250", NULL) == 0);
    else assert(uv_adsp_read_set("1", NULL) == 0 && uv_adsp_raw == 3250);
    assert(calls == 1 && !uv_read_task && !uv_write_task && !exit_at_call);
    assert(uv_adsp_write_set("3250", NULL) == -EOPNOTSUPP);
    assert(uv_adsp_read_set("1", NULL) == -EOPNOTSUPP);
    assert(calls == 1);
    printf("PASS exit during %s: in-flight callback completes; new I/O rejected\n", write ? "write" : "read");
}

int main(void)
{
    struct kernel_param param = { .arg = &uv_adsp_mv };
    test_registration();
    test_unknown_profile();
    test_adsp(0);
    test_adsp(1);
    test_exit_during_io(false);
    test_exit_during_io(true);
    assert(uv_voltage_set("1999", &param) == -EINVAL);
    assert(uv_voltage_set("5001", &param) == -EINVAL);
    assert(uv_voltage_set("2540", &param) == 0 && uv_adsp_mv == 2540);
    puts("PASS voltage bounds");
    return 0;
}
