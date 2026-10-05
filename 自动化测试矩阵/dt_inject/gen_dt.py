#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate fake DT trees for uv_dt_orig failure injection (v2, 2026-10-05).

v1 的问题（v2 修复）：
  1) 每个 case 只在 strategy_ratio_range_high/strategy_temp_warm 下建一张表；
     而标准调用 (cnt=1758 cc=344 temp=300) 解析出 region=3(mid) / index_t=2(normal)
     => 路径不存在 => 9/10 个 case 得到同一条 ERR empty（**假绿**），
     根本没走到它们声称要测的检查。测试"全绿"是假的。
  2) 基线表是手造的非真实数据。
  3) 缺"误杀哨兵"：合法但曾被 v0_order 误拒的真实厂商表。

v2 做法：
  · 基线 = 真机活 DT 语料（<EXTERNAL>/回归检查/corpora/PJZ110_16.0.5.701_C16a_dtb0），
    完整 6 region x 4 temp 网格，保证路径真实存在、基线值 = 真机实测 3250。
  · 缺陷统一注入到【标准调用命中的那张表】= strategy_ratio_range_mid/strategy_temp_normal。
  · 新增 v0drop_ok 哨兵：真实厂商合法 v0 回落表，必须【通过】（守护已删除的 v0_order 不被重新引入）。
  · 输出 manifest.json 供 run_cases.sh 断言。
"""
import os, json, shutil, struct

HERE = os.path.dirname(os.path.abspath(__file__))     # 自动化测试矩阵/dt_inject
ROM  = os.path.dirname(os.path.dirname(HERE))         # 仓库根
# 基线优先用【自包含副本】（随本目录一起携带）；缺失时回退到提取语料目录。
# 自包含是为了让本测试不依赖临时目录 <EXTERNAL>/回归检查/（那是取证会话的工作区，可能被清理）。
BASE_CANDIDATES = [
    os.path.join(HERE, "base/silicon_p_770/ddrc_strategy"),
    os.path.join(ROM, "<EXTERNAL>/回归检查/corpora/PJZ110_16.0.5.701_C16a_dtb0/silicon_p_770/ddrc_strategy"),
]
BASE = next((x for x in BASE_CANDIDATES if os.path.isdir(x)), BASE_CANDIDATES[0])
ROOT = os.path.join(HERE, "dtgen")
BATT = "silicon_p_770"
REGION, TEMP = "strategy_ratio_range_mid", "strategy_temp_normal"   # 标准调用命中的表
TGT = os.path.join(REGION, TEMP)

CORPUS = os.path.dirname(os.path.dirname(BASE))   # <corpus>/  (含 silicon_p_770/ 的电池根)
if not os.path.isdir(BASE):
    raise SystemExit("找不到真机基线语料: %s" % BASE)
if os.path.exists(ROOT):
    shutil.rmtree(ROOT)
os.makedirs(ROOT)

def be32(*vals): return b"".join(struct.pack(">I", v & 0xFFFFFFFF) for v in vals)
def rows_to_bytes(rows): return b"".join(be32(f0, v0, v1, x) for (f0, v0, v1, x) in rows)
def read_rows(p):
    d = open(p, "rb").read()
    return [struct.unpack_from(">4i", d, i) for i in range(0, len(d), 16)]

REAL_MID_NORMAL = read_rows(os.path.join(BASE, TGT))          # 真机基表
REAL_RAW        = open(os.path.join(BASE, TGT), "rb").read()

# 真实厂商"合法 v0 回落"表（取自 C16-16.0.0.212 low/normal，行 0 为基准记录、阶梯从行 1 重起算）
V0_DROP = [(0,3100,3100,0),(15,3000,3060,1),(400,3100,3100,2),(800,3200,3200,3),(1200,3300,3300,4)]

MANIFEST = {}

def mk(name, mutate=None, drop_battery=False, note=""):
    """复制真机完整树，再施加 mutate(树根) 变异。"""
    d = os.path.join(ROOT, name)
    if drop_battery:
        os.makedirs(d, exist_ok=True)            # 只有空目录，没有 battery 子树
    else:
        shutil.copytree(CORPUS, d)                      # 复制 <corpus>/ -> d/silicon_p_770/...
    if mutate:
        mutate(os.path.join(d, BATT, "ddrc_strategy"))
    return name

def set_target_tbl(ddrc, blob):
    open(os.path.join(ddrc, TGT), "wb").write(blob)

# ---- 正常基线 ----
mk("valid")
MANIFEST["valid"] = {"expect": "ok", "value": 3250,
                     "why": "真机活 DT 原样（6x4 完整网格），标准调用应得 3250"}

# ---- 项数类 ----
def _rm_rr(ddrc): os.remove(os.path.join(ddrc, "oplus,ratio_range"))
mk("rr_missing", _rm_rr); MANIFEST["rr_missing"] = {"expect":"fail","reason":"ratio_range 项数=0","why":"缺 oplus,ratio_range"}
def _rr4(ddrc): open(os.path.join(ddrc,"oplus,ratio_range"),"wb").write(be32(20,30,50,70))
mk("rr4", _rr4); MANIFEST["rr4"] = {"expect":"fail","reason":"ratio_range 项数=4","why":"ratio_range 写成 4 项"}
def _tr2(ddrc): open(os.path.join(ddrc,"oplus,temp_range"),"wb").write(be32(0xFFFFFFCE,100))
mk("tr2", _tr2); MANIFEST["tr2"] = {"expect":"fail","reason":"temp_range 项数=2","why":"temp_range 写成 2 项"}

# ---- 表结构类（全部注入 mid/normal，即标准调用命中的表）----
def _f0base(ddrc):
    r = list(REAL_MID_NORMAL); r[0] = (5,) + tuple(r[0][1:])
    set_target_tbl(ddrc, rows_to_bytes(r))
mk("f0base", _f0base); MANIFEST["f0base"] = {"expect":"fail","reason":"ERR f0_base","why":"首行 f0 != 0"}

def _f0order(ddrc):
    r = list(REAL_MID_NORMAL)
    if len(r) >= 3:
        r[2] = (max(0, r[1][0] - 1),) + tuple(r[2][1:])
    else:
        r = r + [(0,3000,3000,0)]
    set_target_tbl(ddrc, rows_to_bytes(r))
mk("f0order", _f0order); MANIFEST["f0order"] = {"expect":"fail","reason":"ERR f0_order","why":"第 3 行 f0 小于第 2 行（i>=2 处回落）"}

def _size(ddrc): set_target_tbl(ddrc, REAL_RAW + b"\x00")
mk("size_bad", _size); MANIFEST["size_bad"] = {"expect":"fail","reason":"ERR size","why":"追加 1 字节，字节数 %16 != 0"}

def _rows9(ddrc):
    row = REAL_MID_NORMAL[0]
    set_target_tbl(ddrc, rows_to_bytes([(i*10, row[1], row[2], 0) for i in range(9)]))
mk("rows9", _rows9); MANIFEST["rows9"] = {"expect":"fail","reason":"ERR rows","why":"9 行，超出 1~8"}

def _volt_hi(ddrc):
    r = list(REAL_MID_NORMAL); r[-1] = tuple(r[-1][:2]) + (60000, 0)
    set_target_tbl(ddrc, rows_to_bytes(r))
mk("volt_hi", _volt_hi); MANIFEST["volt_hi"] = {"expect":"fail","reason":"ERR volt_range","why":"末行 v1=60000，超出 2000~5000"}

def _oob(ddrc):
    # 选中行（f0 <= cc=344）的 v1 = 2600：volt_range 通过，但结果越过 [2900,3500]
    set_target_tbl(ddrc, rows_to_bytes([(0,3000,2600,0),(400,3100,3150,1),(800,3200,3250,2)]))
mk("oob_2600", _oob); MANIFEST["oob_2600"] = {"expect":"fail","reason":"结果越界","why":"选中行 v1=2600，在 2000~5000 内但低于结果带下界 2900"}

def _misparse12(ddrc):
    # 真实 4 行 x 16B -> 每行只留 (f0,v0,v1) = 4x12B = 48B，48%16==0 绕过 size 检查
    blob = b"".join(be32(r[0], r[1], r[2]) for r in REAL_MID_NORMAL)
    set_target_tbl(ddrc, blob)
mk("misparse12", _misparse12); MANIFEST["misparse12"] = {"expect":"fail","reason":"ERR volt_range","why":"12 B/行 错位形态（48B 绕过 size），应由 volt_range 拦下"}

# ---- 误杀哨兵：合法 v0 回落，必须【通过】----
def _v0drop(ddrc): set_target_tbl(ddrc, rows_to_bytes(V0_DROP))
mk("v0drop_ok", _v0drop)
MANIFEST["v0drop_ok"] = {"expect":"ok","value":3060,
    "why":"真实厂商合法 v0 回落表（行0 基准 3100 -> 行1 3000）。曾被已删除的 v0_order 误拒；本用例守护它不被重新引入"}

# ---- 无 battery 节点 ----
mk("empty", drop_battery=True); MANIFEST["empty"] = {"expect":"fail","reason":"未找到含 ddrc_strategy","why":"根本没有 battery 子树"}

with open(os.path.join(ROOT, "manifest.json"), "w") as f:
    json.dump(MANIFEST, f, ensure_ascii=False, indent=2)

print("%-14s %-8s %-28s %s" % ("CASE", "EXPECT", "VALUE/REASON", "WHY"))
for k in sorted(MANIFEST):
    m = MANIFEST[k]
    print("%-14s %-8s %-28s %s" % (k, m["expect"], m.get("value", m.get("reason","")), m["why"][:60]))
print("\nGEN_OK  cases=%d  base=%s" % (len(MANIFEST), os.path.relpath(BASE, ROM)))
