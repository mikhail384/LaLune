import http.server, urllib.request, urllib.error, urllib.parse, secrets, mimetypes, os, sys, hmac, threading
from pathlib import Path
root=Path(sys.argv[1]).resolve(); bootstrap=sys.argv[2]; secret=secrets.token_urlsafe(48); launch_lock=threading.Lock(); launched=False; port=int(sys.argv[3]); token=Path.home().joinpath('.la-lune/native-api-token').read_text().strip(); host=f'127.0.0.1:{port}'
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def valid(self):
  return self.headers.get('Host','') == host and hmac.compare_digest(self.headers.get('Cookie','').replace('session=',''),secret) and self.headers.get('Sec-Fetch-Site','same-origin') in ('same-origin','none') and (not self.headers.get('Origin') or self.headers['Origin']==f'http://{host}')
 def send_common(self):
  self.send_header('X-Content-Type-Options','nosniff'); self.send_header('Cache-Control','no-store')
 def handle_request(self):
  path=urllib.parse.urlsplit(self.path).path
  if self.headers.get('Host')!=host: self.send_error(403); return
  global launched
  if path=='/launch/'+bootstrap:
   with launch_lock:
    if launched: self.send_error(403); return
    launched=True
   self.send_response(303); self.send_header('Set-Cookie','session='+secret+'; HttpOnly; SameSite=Strict; Path=/'); self.send_header('Location','/'); self.send_common(); self.end_headers(); return
  if not self.valid(): self.send_error(403); return
  filename=(root / urllib.parse.unquote(path).lstrip('/')).resolve()
  if self.command=='GET' and (filename==root or root in filename.parents):
   if filename.is_dir(): filename=filename/'index.html'
   if filename.is_file():
    content=filename.read_bytes(); self.send_response(200); self.send_header('Content-Type',mimetypes.guess_type(str(filename))[0] or 'application/octet-stream'); self.send_header('Content-Length',str(len(content))); self.send_common(); self.end_headers(); self.wfile.write(content); return
  length=int(self.headers.get('Content-Length','0')); body=self.rfile.read(length) if length else None
  req=urllib.request.Request('http://127.0.0.1:1062'+self.path,data=body,method=self.command,headers={'X-LaLune-Token':token,'Content-Type':self.headers.get('Content-Type','application/json')})
  try: res=urllib.request.urlopen(req,timeout=100)
  except urllib.error.HTTPError as e: res=e
  except Exception: self.send_error(502); return
  self.send_response(res.status); self.send_header('Content-Type',res.headers.get('Content-Type','application/json')); self.send_common(); self.end_headers()
  try:
   while True:
    chunk=res.read(8192)
    if not chunk: break
    self.wfile.write(chunk); self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError,TimeoutError): pass
  finally: res.close()
 do_GET=do_POST=do_PUT=do_PATCH=do_DELETE=handle_request
server=http.server.ThreadingHTTPServer(('127.0.0.1',port),Handler)
port=server.server_address[1]; host=f'127.0.0.1:{port}'
print(port,flush=True)
server.serve_forever()
