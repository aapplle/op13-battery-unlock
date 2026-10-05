#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""uv_dt_orig 失败注入用例运行器（断言版，2026-10-05）

背景：v1 的语料生成器只在 high/warm 下建表，而标准调用落在 mid/normal，
      导致 9/10 个用例得到同一条 ERR empty —— 测试"全绿"是**假绿**。
      本运行器对每个用例断言【预期结果】，假绿会被判 FAIL。

用法：
    python3 自动化测试矩阵/dt_inject/run_cases.py            # 跑全部
    python3 自动化测试矩阵/dt_inject/run_cases.py valid rr4  # 只跑指定用例
退出码：0 = 全部符合预期；1 = 有 FAIL

位置无关：路径全部相对本文件定位（HERE = 本脚本所在目录），整体搬移不影响运行。
"""
import os, sys, json, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))     # 自动化测试矩阵/dt_inject
ROM  = os.path.dirname(os.path.dirname(HERE))         # 仓库根
LOG  = os.environ.get("UV_DT_LOG", os.path.join(ROM, "模块源目录/log.sh"))   # 可覆盖：用于哨兵自测
ROOT = os.path.join(HERE, "dtgen")
MAN  = json.load(open(os.path.join(ROOT, "manifest.json")))

# 标准调用：与真机当前工况一致 -> region=3(mid) / index_t=2(normal)
UV = {"UV_T_BATT": "silicon_p_770", "UV_T_CNT": "1758",
      "UV_T_CC": "344", "UV_T_CALI": "0", "UV_T_TEMP": "300"}

def run(case):
    env = dict(os.environ)
    env.update(UV)
    env["UV_T_DTB"] = os.path.join(ROOT, case)
    # 用临时文件中转，避免"值为空时 RC 不在新行"的解析歧义
    fo, fr = "/tmp/_uvout.%d" % os.getpid(), "/tmp/_uvrc.%d" % os.getpid()
    cmd = '. "%s"; uv_dt_orig > %s; echo $? > %s' % (LOG, fo, fr)
    r = subprocess.run(["sh", "-c", cmd], env=env, capture_output=True, text=True)
    out = open(fo).read().strip() if os.path.exists(fo) else ""
    rc  = int(open(fr).read().strip()) if os.path.exists(fr) else 1
    for f in (fo, fr):
        if os.path.exists(f):
            os.remove(f)
    return out, rc, r.stderr

def main():
    only = sys.argv[1:]
    cases = [c for c in sorted(MAN) if not only or c in only]
    rows, fails = [], 0
    for c in cases:
        exp = MAN[c]
        out, rc, err = run(c)
        reason = [l for l in err.splitlines() if "FAIL" in l]
        reason = reason[0] if reason else ""
        if exp["expect"] == "ok":
            ok = (out == str(exp["value"])) and rc == 0
            want = "值=%s rc=0" % exp["value"]
            got = "值=%s rc=%s" % (out or "(空)", rc)
        else:
            ok = (out == "") and rc != 0 and (exp["reason"] in reason)
            want = "失败且原因含 %r" % exp["reason"]
            got = "值=%s rc=%s 原因=%s" % (out or "(空)", rc, reason.split("] ")[-1][:70] or "(无)")
        if not ok:
            fails += 1
        rows.append((c, exp["expect"], "PASS" if ok else "FAIL", want, got))

    w = max(len(r[0]) for r in rows) if rows else 4
    print("%-*s %-6s %-5s %s" % (w, "CASE", "EXPECT", "判定", "实际"))
    print("-" * (w + 60))
    for c, e, v, want, got in rows:
        print("%-*s %-6s %-5s %s" % (w, c, e, v, got))
        if v == "FAIL":
            print("%-*s %-6s %-5s   期望: %s" % (w, "", "", "", want))
    print("\n合计 %d 例，PASS %d，FAIL %d" % (len(rows), len(rows) - fails, fails))
    if fails:
        print("\n!! 有用例未达预期 —— 这才是真信号，不要忽略")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
