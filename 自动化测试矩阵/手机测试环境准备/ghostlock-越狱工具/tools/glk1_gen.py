#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GLK1 profile 生成器：把官方提取器产出的 .conf 合并进一份【已知可用】的 GLK1，
产出目标内核可直接 --load-prebuilt-profile 的 profile.bin。

为什么这么做：
  * profile.bin 是 GLK1 v2 二进制（格式见 ghostlock-app/src/core/profile/binary.h）
  * 官方 App 走 HOCON→GLK1 的转换；没有 App 时（本项目用 CLI）需要自己转
  * task_struct / cred / 路由与 execution 调优在 6.x 族里是【逐字节相同】的
    （仓库里 6.6.30 ~ 6.6.127 的 .conf 实测只有 offset{} 符号偏移不同）
    → 保留已知可用文档的形状与调优值，只替换 release / task_struct / cred / offset / kernelsnitch

用法：glk1_gen.py <已知可用.bin> <提取器.conf> <输出.bin>
"""
import struct, sys, re

def decode(p):
    d = open(p, 'rb').read(); o = 0
    magic, ver, fe, be, mw, rl = struct.unpack_from('<IHHHHH', d, o); o += 16
    assert magic == 0x0D000721 and ver == 2, 'not GLK1 v2'
    rel = d[o:o+rl].decode(); o += rl
    nsec, = struct.unpack_from('<H', d, o); o += 2
    secs = []
    for _ in range(nsec):
        nl = d[o]; o += 1; name = d[o:o+nl].decode(); o += nl
        cnt, = struct.unpack_from('<I', d, o); o += 4
        ents = []
        for _ in range(cnt):
            kl = d[o]; o += 1; k = d[o:o+kl].decode(); o += kl
            v, = struct.unpack_from('<q', d, o); o += 8
            ents.append([k, v])
        secs.append([name, ents])
    assert o == len(d), 'trailing bytes: %d/%d' % (o, len(d))
    return rel, (fe, be, mw), secs

def encode(rel, ids, secs):
    out = bytearray()
    rb = rel.encode()
    # 头部固定 16 字节：u32 magic + 5×u16 字段（14 B）+ 2 B 对齐填充
    # （见 binary.cpp: kHeaderSize=16；release 从第 16 字节开始）
    # 注意 middleware 字段同时编码【路由选择】：2 = kRouteSelectStack
    out += struct.pack('<IHHHHH', 0x0D000721, 2, ids[0], ids[1], ids[2], len(rb))
    out += b'\x00\x00'
    out += rb
    out += struct.pack('<H', len(secs))
    for name, ents in secs:
        nb = name.encode()
        out += bytes([len(nb)]) + nb + struct.pack('<I', len(ents))
        for k, v in ents:
            kb = k.encode()
            out += bytes([len(kb)]) + kb + struct.pack('<q', v)
    return bytes(out)

def parse_conf(p):
    """极简 HOCON 子集解析：block { ... } / key = value，忽略注释与 # 行"""
    txt = open(p, encoding='utf-8').read()
    txt = re.sub(r'#[^\n]*', '', txt)
    root = {}; stack = []; cur = root
    for line in txt.splitlines():
        line = line.strip()
        if not line: continue
        if line.endswith('{'):
            name = line[:-1].strip()
            new = {}
            cur[name] = new
            stack.append(cur); cur = new
        elif line == '}':
            cur = stack.pop() if stack else root
        elif '=' in line:
            k, v = line.split('=', 1)
            k, v = k.strip(), v.strip()
            if v == 'null': cur[k] = None
            elif v.startswith('"'): cur[k] = v.strip('"')
            else:
                try: cur[k] = int(v, 0)
                except ValueError: cur[k] = v
    return root

def main():
    base_bin, conf_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    rel_b, ids, secs = decode(base_bin)
    c = parse_conf(conf_path)
    new_rel = c['release']

    # conf 节 → GLK1 节 的取值映射（None = 该字段在 6.x 未使用，写 0 与省略等价）
    overrides = {
        'task_struct': c.get('task_struct', {}),
        'cred':        c.get('cred', {}),
        'offset':      c.get('offset', {}),
    }
    # kernel 节：只取 kernelsnitch.collisions → kernelsnitch_collisions
    # 【不写】kernel_phys_load / kernel_phys_offset：提取器在 PC 上读到的是宿主
    # /proc/iomem，对手机无效；官方 6.6 profile 也是省略（运行时按 SoC 公式回退）
    ks = (c.get('kernelsnitch') or {}).get('collisions')

    changed = []
    for name, ents in secs:
        if name == 'meta':
            for e in ents:
                if e[0] == 'kernel_major' and 'kernel_major' in c: e[1] = c['kernel_major']
                if e[0] == 'recommend_shizuku' and c.get('recommend_shizuku') is not None:
                    e[1] = c['recommend_shizuku']
        elif name in overrides:
            src = overrides[name]
            for e in ents:
                if e[0] in src:
                    v = src[e[0]]
                    nv = 0 if v is None else int(v)
                    if nv != e[1]: changed.append('%s.%s: %s -> %s' % (name, e[0], e[1], nv))
                    e[1] = nv
        elif name == 'kernel':
            for e in ents:
                if e[0] == 'kernelsnitch_collisions' and ks is not None:
                    if e[1] != ks: changed.append('kernel.kernelsnitch_collisions: %s -> %s' % (e[1], ks))
                    e[1] = ks

    blob = encode(new_rel, ids, secs)
    open(out_path, 'wb').write(blob)
    print('release : %s -> %s' % (rel_b, new_rel))
    print('size    : %d B -> %d B' % (len(open(base_bin,'rb').read()), len(blob)))
    print('变更 %d 项：' % len(changed))
    for x in changed: print('   ' + x)

main()
