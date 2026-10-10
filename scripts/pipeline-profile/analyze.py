#!/usr/bin/env python3
"""Aggregate stage timings and match Zlib output sizes to server responses."""
from pathlib import Path
from collections import defaultdict
import bisect, gzip, json, math, statistics, sys
root=Path(sys.argv[1]); client=sys.argv[2] if len(sys.argv)>2 else 'client-v3.csv'
def read(name):
 rows=[]
 path=root/name
 text=path.read_text() if path.exists() else gzip.open(str(path)+'.gz','rt').read()
 for line in text.splitlines():
  p=line.split(',')
  if len(p)!=6:continue
  try:rows.append(dict(name=p[0],start=int(p[1]),wall=int(p[2]),cpu=int(p[3]),thread=int(p[4]),info=p[5]))
  except ValueError:pass
 return sorted(rows,key=lambda x:x['start'])
def attrs(r):return dict(t.split('=',1)for t in r['info'].split(';')if '='in t)
def stats(v):
 if not v:return None
 v=sorted(v)
 return {'n':len(v),'mean':statistics.mean(v),'p50':statistics.median(v),'p95':v[min(len(v)-1,math.ceil(len(v)*.95)-1)],'max':v[-1]}
s=read('server.csv');c=read(client);clientstart=c[0]['start'];s=[r for r in s if r['start']>=clientstart]
sent=[r for r in s if r['name']=='response_sent'];inflates=[r for r in c if r['name']=='client_inflate'];draws=[r for r in c if r['name']=='client_draw_submit'];drawtimes=[r['start']for r in draws];callbacks=[r for r in c if r['name']=='client_framebuffer_updated'];callbacktimes=[r['start']for r in callbacks]
# Output length gives an unambiguous stream boundary, including multi-rectangle frames.
i=0;matched=[]; mismatch=None; incomplete_tail=None
for f in sent:
 a=attrs(f);needed=int(a['pixels'])*4
 if not needed:continue
 used=[];n=0
 while n<needed and i<len(inflates):
  used.append(inflates[i]);n+=int(inflates[i]['info']);i+=1
 if n!=needed:
  failure={'needed':needed,'got':n,'at':f['start']}
  if n<needed and i==len(inflates):incomplete_tail=failure
  else:mismatch=failure
  break
 end=used[-1]['start']+used[-1]['wall'];ci=bisect.bisect_left(callbacktimes,end)
 if ci>=len(callbacks):break
 end=callbacks[ci]['start']+callbacks[ci]['wall'];di=bisect.bisect_left(drawtimes,end)
 matched.append({'sent':f,'decode_start':used[0]['start'],'decode_end':end,'inflate_wall':sum(x['wall']for x in used),'inflate_cpu':sum(x['cpu']for x in used),'draw':draws[di]if di<len(draws)else None})
# Capture timestamp lookup includes the whole trace; sequence is per source, not per client.
ready={int(attrs(r)['seq']):r for r in read('server.csv')if r['name']=='capture_ready'}
spans=[r for r in s if r['name']=='response_including_throttle'];starts=[r['start']for r in spans]
for m in matched:
 f=m['sent'];j=bisect.bisect_right(starts,f['start'])-1
 m['span']=spans[j]if j>=0 and spans[j]['start']+spans[j]['wall']>=f['start']else None
 m['capture']=ready.get(int(attrs(f)['seq']))
results={'matched_frames':len(matched),'boundary_mismatch':mismatch,'incomplete_tail':incomplete_tail,'phases':{}}
for fn in sorted(root.glob('*-cpu.json')):
 d=json.loads(fn.read_text());t0=d.get('start_uptime_ns');t1=d.get('end_uptime_ns')
 if t0 is None:continue
 phase={'duration_s':d['duration_s'],'cpu_percent':{pid:p['cpu_percent']for pid,p in d['processes'].items()},'stages':{},'per_sent_frame':{}}
 for who,rows in [('server',s),('client',c)]:
  grouped=defaultdict(list)
  for r in rows:
   if t0<=r['start']<t1 and r['wall']>0:grouped[r['name']].append(r)
  for name,rs in grouped.items():phase['stages'][name]={'wall_ms':stats([r['wall']/1e6 for r in rs]),'cpu_ms':stats([r['cpu']/1e6 for r in rs]),'cpu_ms_per_s':sum(r['cpu']for r in rs)/1e6/d['duration_s']}
 fs=[f for f in sent if t0<=f['start']<t1];phase['responses']=len(fs);phase['responses_per_s']=len(fs)/d['duration_s'];phase['rfb_MB_per_s']=sum(int(attrs(f)['bytes'])for f in fs)/1e6/d['duration_s'];phase['changed_pixels']=stats([int(attrs(f)['pixels'])for f in fs]);phase['rectangles']=stats([int(attrs(f)['rects'])for f in fs])
 ms=[m for m in matched if t0<=m['sent']['start']<t1]
 phase['matching_validation']={'nonempty_responses':sum(int(attrs(f)['pixels'])>0 for f in fs),'matched_frames':len(ms)}
 phase['frame_latency_ms']={
  'response_including_throttle':stats([m['span']['wall']/1e6 for m in ms if m['span']]),
  'response_thread_cpu':stats([m['span']['cpu']/1e6 for m in ms if m['span']]),
  'capture_pts_to_client_framebuffer':stats([(m['decode_end']-float(attrs(m['capture'])['pts'])*1e9)/1e6 for m in ms if m['capture']]),
  'capture_pts_to_ready':stats([(m['capture']['start']-float(attrs(m['capture'])['pts'])*1e9)/1e6 for m in ms if m['capture']]),
  'send_complete_to_decode_complete':stats([(m['decode_end']-m['sent']['start'])/1e6 for m in ms]),
  'capture_ready_to_decode_complete':stats([(m['decode_end']-m['capture']['start'])/1e6 for m in ms if m['capture']]),
  'inflate_wall_per_frame':stats([m['inflate_wall']/1e6 for m in ms]),
  'inflate_cpu_per_frame':stats([m['inflate_cpu']/1e6 for m in ms]),
  # First subsequent draw is a scheduling observation, not frame identity or display scanout.
  'decode_to_next_draw_submit':stats([(m['draw']['start']+m['draw']['wall']-m['decode_end'])/1e6 for m in ms if m['draw']])}
 for name in ['fps_wait','snapshot_cursor_scale','dirty_region_diff','pixel_pack','zlib_deflate','aes_record_seal','socket_write_raw','encrypt_and_write']:
  vals=[];cpuvals=[]
  relevant=[r for r in s if r['name']==name]; times=[r['start']for r in relevant]
  for m in ms:
   span=m['span']
   if not span:continue
   rs=[r for r in relevant[bisect.bisect_left(times,span['start']):bisect.bisect_left(times,span['start']+span['wall'])] if r['thread']==span['thread']]
   vals.append(sum(r['wall']for r in rs)/1e6);cpuvals.append(sum(r['cpu']for r in rs)/1e6)
  phase['per_sent_frame'][name]={'wall_ms':stats(vals),'cpu_ms':stats(cpuvals)}
 results['phases'][d['scenario']]=phase
(root/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
