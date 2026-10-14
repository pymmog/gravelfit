#!/usr/bin/env python3
"""A tiny uncompressed QuickTime fixture; each sample references the same solid-color frame.

No hardware encoder, network, runtime Python process, or third-party dependency is needed.
"""
from pathlib import Path
import struct
def u32(*v): return struct.pack('>'+'I'*len(v),*v)
def u16(*v): return struct.pack('>'+'H'*len(v),*v)
def atom(kind,data): return u32(len(data)+8)+kind.encode()+data
def full(kind,data,flags=0): return atom(kind,u32(flags)+data)
matrix=u32(0x10000,0,0,0,0x10000,0,0,0,0x40000000)
w,h,n=320,240,30
ftyp=atom('ftyp',b'qt  '+u32(0)+b'qt  ')
frame=bytes([40,40,40])*(w*h)
offset=len(ftyp)+8
mdat=atom('mdat',frame)
mvhd=full('mvhd',u32(0,0,30,n,0x10000)+u16(0x100)+bytes(10)+matrix+bytes(24)+u32(2))
tkhd=full('tkhd',u32(0,0,1,0,n)+bytes(8)+u16(0,0,0,0)+matrix+u32(w<<16,h<<16),3)
mdhd=full('mdhd',u32(0,0,30,n)+u16(0,0))
hdlr=full('hdlr',u32(0)+b'vide'+bytes(12)+b'GravelFit fixture\0')
vmhd=full('vmhd',u16(0,0,0,0),1)
dinf=atom('dinf',full('dref',u32(1)+full('url ',b'',1)))
desc=bytes(6)+u16(1)+u16(0,0)+bytes(12)+u16(w,h)+u32(0x480000,0x480000,0)+u16(1)+bytes(32)+u16(24,0xffff)
stsd=full('stsd',u32(1)+atom('raw ',desc))
stts=full('stts',u32(1,n,1))
stsc=full('stsc',u32(1,1,1,1))
stsz=full('stsz',u32(len(frame),n))
stco=full('stco',u32(n)+u32(*([offset]*n)))
stbl=atom('stbl',stsd+stts+stsc+stsz+stco)
minf=atom('minf',vmhd+dinf+stbl)
mdia=atom('mdia',mdhd+hdlr+minf)
moov=atom('moov',mvhd+atom('trak',tkhd+mdia))
dest=Path(__file__).resolve().parent.parent/'GravelFitTests/Fixtures/blank.mov'
dest.parent.mkdir(parents=True,exist_ok=True)
dest.write_bytes(ftyp+mdat+moov)
print(f'Generated {dest.name} ({dest.stat().st_size} bytes)')
