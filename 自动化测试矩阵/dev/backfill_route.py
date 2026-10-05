#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给【早于路线自动判定】的历史测试结果回填启动路线声明。

背景：2026-10-04 21:04 之前，设备一直是 ghostlock 越狱（late-load）态，
      但报告里没有记录路线字段 —— 换 ROM/内核做兼容性矩阵时无法自证。
本脚本只做**追加声明**，不改动任何已有字段/结论。

证据分级：
  evidence  —— report.jsonl 里 T4.1 PASS 且命中断言「主动触发 deep_dischg」。
               该日志只在模块【需要主动捕获 uv_dev】时出现，即越狱路线；
               标准启动下由驱动开机 vote 自动捕获，不会打这条。
  inferred  —— 该批次无直接证据（未跑 T4 组），但设备当时为 ghostlock 越狱态。
  none      —— 无 report.jsonl，仅标注 unknown。

用法：
  python3 dev/backfill_route.py --dry-run     # 只看会改什么
  python3 dev/backfill_route.py               # 实际写入
"""
import json, os, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(os.path.dirname(HERE), "results")
DRY = "--dry-run" in sys.argv

EVID = "T4.1 PASS 且命中断言「主动触发 deep_dischg」（越狱路线专有：标准启动由驱动开机 vote 自动捕获）"
INFER = "该批次早于路线自动判定；设备当时为 ghostlock 越狱态（无直接证据，判为 late-load）"


def evidence(d):
    jl = os.path.join(d, "report.jsonl")
    if not os.path.exists(jl):
        return "none", "无 report.jsonl，路线未记录"
    hit = False
    for line in open(jl, encoding="utf-8", errors="replace"):
        if '"case":"T4.1"' in line and '"result":"PASS"' in line:
            if "主动触发 deep_dischg" in line:
                return "evidence", EVID
            hit = True
    if hit:
        return "inferred", INFER + "（T4.1 存在但未命中该日志）"
    return "inferred", INFER


def patch_json(p, route, src, ev):
    with open(p, encoding="utf-8") as f:
        data = json.load(f)
    if data.get("boot_route"):
        return False
    data["boot_route"] = route
    data["route_src"] = src
    data["route_evidence"] = ev
    data["route_backfill"] = True
    if not DRY:
        with open(p, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
    return True


def patch_md(p, route, src, ev):
    with open(p, encoding="utf-8") as f:
        txt = f.read()
    if "启动路线" in txt:
        return False
    lines = txt.split("\n")
    out, done = [], False
    for ln in lines:
        if not done and ln.startswith("- **被测构建"):
            out.append("- **启动路线：`%s`**（回填声明 · 来源 `%s`）" % (route, src))
            out.append("  - 依据：%s" % ev)
            done = True
        out.append(ln)
    if not DRY:
        with open(p, "w", encoding="utf-8") as f:
            f.write("\n".join(out))
    return done


def main():
    dirs = sorted(glob.glob(os.path.join(RESULTS, "*", "")))
    n_ev = n_in = n_none = n_skip = 0
    for d in dirs:
        rj = os.path.join(d, "report.json")
        rm = os.path.join(d, "report.md")
        name = os.path.basename(d.rstrip("/"))
        if not os.path.exists(rj):
            print("%-18s 无 report.json → 跳过" % name)
            n_skip += 1
            continue
        grade, ev = evidence(d)
        try:
            changed = patch_json(rj, "late-load", "backfill-" + grade, ev)
        except Exception as e:
            print("%-18s report.json 解析失败：%s → 跳过" % (name, e))
            n_skip += 1
            continue
        if not changed:
            print("%-18s 已有 boot_route → 跳过" % name)
            n_skip += 1
            continue
        md_ok = patch_md(rm, "late-load", "backfill-" + grade, ev) if os.path.exists(rm) else False
        tag = {"evidence": "证据", "inferred": "推断", "none": "无据"}[grade]
        print("%-18s → late-load（%s）%s" % (name, tag, "" if md_ok else " [report.md 未改]"))
        if grade == "evidence": n_ev += 1
        elif grade == "inferred": n_in += 1
        else: n_none += 1
    print("\n合计：证据 %d · 推断 %d · 无据 %d · 跳过 %d%s"
          % (n_ev, n_in, n_none, n_skip, "（--dry-run，未写入）" if DRY else ""))


main()
