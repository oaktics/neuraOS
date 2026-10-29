# Read-only macOS process sampling. Never reads argv, environment, tokens or DB.
import ctypes, json, os, re, subprocess, time
header=open('/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/resource.h').read()
body=header.split('struct rusage_info_v2 {',1)[1].split('};',1)[0]
fields=re.findall(r'uint64_t\s+(\w+);',body)
class Usage(ctypes.Structure):
 _fields_=[('uuid',ctypes.c_ubyte*16)]+[(name,ctypes.c_uint64) for name in fields]
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
rows=[]
for line in subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines():
 p=line.split(None,2)
 if len(p)==3: rows.append((int(p[0]),int(p[1]),p[2]))
roots=[p for p,_,name in rows if '/neuraOS.app/Contents/' in name and (name.endswith('/NeuraOS') or name.endswith('/node'))]
owned=set(roots)
while True:
 new=owned|{p for p,parent,_ in rows if parent in owned}
 if new==owned:break
 owned=new
selected=[(p,parent,os.path.basename(name)) for p,parent,name in rows if p in owned]
def snap():
 out={}
 for pid,_,_ in selected:
  value=Usage()
  if lib.proc_pid_rusage(pid,2,ctypes.byref(value))==0:out[pid]={key:getattr(value,key) for key in fields}
 return out
start=time.monotonic();a=snap();time.sleep(10);b=snap();duration=time.monotonic()-start
result=[]
for pid,parent,name in selected:
 if pid not in a or pid not in b:continue
 before,after=a[pid],b[pid]
 result.append({'pid':pid,'ppid':parent,'name':name,'residentBytes':after['ri_resident_size'],'footprintBytes':after['ri_phys_footprint'],**{k:after[k]-before[k] for k in ['ri_user_time','ri_system_time','ri_pkg_idle_wkups','ri_interrupt_wkups','ri_diskio_bytesread','ri_diskio_byteswritten','ri_pageins']}})
class Timebase(ctypes.Structure):
 _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
timebase=Timebase();ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(timebase))
print(json.dumps({'cpuTimeUnit':'mach ticks','timebaseNumer':timebase.numer,'timebaseDenom':timebase.denom,'durationSeconds':duration,'scope':'running neuraOS roots and observed descendants; not idle or controlled load','processes':result},indent=2))
