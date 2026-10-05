#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""哨兵自测：把已删除的 v0_order 检查注回一份 log.sh 副本。

用途：验证 自动化测试矩阵/dt_inject/run_cases.py 中的 v0drop_ok / valid 用例
      能抓到"v0_order 被重新引入"这一类回归。
用法：python3 自动化测试矩阵/dt_inject/mk_v0order_variant.py [输出路径]
"""
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
ROM  = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(ROM, "模块源目录/log.sh")
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/log_with_v0order.sh"

src = open(SRC).read()
n0 = src.count("first = -1; tgt = -1; prev = -1")
src = src.replace("        first = -1; tgt = -1; prev = -1",
                  "        first = -1; tgt = -1; prev = -1; prev0 = -1", 1)
n1 = src.count("else if (f0 < prev) { print \"ERR f0_order\"; exit }")
src = src.replace("            else if (f0 < prev) { print \"ERR f0_order\"; exit }",
                  "            else if (f0 < prev) { print \"ERR f0_order\"; exit }\n"
                  "            if (i > 0 && prev0 > 0 && v0 < prev0) { print \"ERR v0_order\"; exit }", 1)
n2 = src.count("            prev = f0\n")
src = src.replace("            prev = f0\n", "            prev = f0; prev0 = v0\n", 1)

ok = (n0 == 1 and n1 == 1 and n2 >= 1 and "ERR v0_order" in src)
open(OUT, "w").write(src)
print("patch: init=%d f0order=%d prev=%d -> %s (%s)" % (n0, n1, n2, OUT, "OK" if ok else "PATCH-FAILED"))
sys.exit(0 if ok else 1)
