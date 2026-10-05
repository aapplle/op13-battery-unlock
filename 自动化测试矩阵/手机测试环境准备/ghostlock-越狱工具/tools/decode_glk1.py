import struct, sys
d=open(sys.argv[1],'rb').read()
o=0
magic,ver,fe,be,mw,rl = struct.unpack_from('<IHHHHH', d, o); o+=16
print('magic=0x%08X ver=%d frontend=%d backend=%d middleware=%d release_len=%d'%(magic,ver,fe,be,mw,rl))
rel=d[o:o+rl].decode(); o+=rl
print('release=%r'%rel)
nsec,=struct.unpack_from('<H',d,o); o+=2
print('sections=%d'%nsec)
for s in range(nsec):
    nl=d[o]; o+=1; name=d[o:o+nl].decode(); o+=nl
    cnt,=struct.unpack_from('<I',d,o); o+=4
    print('  [%s] %d entries'%(name,cnt))
    for e in range(cnt):
        kl=d[o]; o+=1; k=d[o:o+kl].decode(); o+=kl
        v,=struct.unpack_from('<q',d,o); o+=8
        print('      %-24s = %d'%(k,v))
print('consumed %d / %d bytes'%(o,len(d)))
