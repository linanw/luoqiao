from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import subprocess,tempfile,os,concurrent.futures,re
pool=concurrent.futures.ThreadPoolExecutor(max_workers=24)
def fetch(url,path,ran=None):
 args=['curl','-fsSL','--retry','3','--max-time','600']
 if ran:args+=['-r',ran]
 subprocess.run(args+[url,'-o',path],check=True)
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path == '/ready':
   self.send_response(200);self.end_headers();return
  if '..' in self.path:self.send_error(400);return
  url='https://proxy.golang.org'+self.path
  if self.path == '/sumdb/sum.golang.org/supported':
   self.send_response(200);self.end_headers();return
  if self.path.startswith('/sumdb/sum.golang.org/'):
   url='https://sum.golang.org/'+self.path.removeprefix('/sumdb/sum.golang.org/')
  try:
   with tempfile.TemporaryDirectory() as d:
    if self.path.endswith('.zip'):
     h=subprocess.check_output(['curl','-fsSIL','--max-time','30',url]).decode()
     lengths=re.findall(r'content-length: (\d+)',h,re.I)
     n=int(lengths[-1]);size=524288
     if n <= 0: raise ValueError('Invalid module length')
     paths=[d+'/'+str(i) for i in range(0,n,size)]
     futures=[pool.submit(fetch,url,p,f'{i}-{min(i+size,n)-1}') for i,p in zip(range(0,n,size),paths)]
     for f in futures:f.result()
     for i,p in zip(range(0,n,size),paths):
      if os.path.getsize(p) != min(size,n-i): raise ValueError('Invalid range response length')
    else:
     paths=[d+'/body'];fetch(url,paths[0]);n=os.path.getsize(paths[0])
    self.send_response(200);self.send_header('Content-Length',str(n));self.end_headers()
    for p in paths:
     with open(p,'rb') as f:
      while b:=f.read(1048576):self.wfile.write(b)
  except Exception as e: print(e,flush=True);self.send_error(502)
ThreadingHTTPServer(('127.0.0.1',18763),Handler).serve_forever()
