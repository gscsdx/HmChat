import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),ts=require(process.env.HARLGRAM_TYPESCRIPT);
const model=require('../artifacts/tests/js/model/VideoPlayback.js');
function fixture(read=async(o,n)=>new Uint8Array(n).fill(o%256).buffer){
 let closed=0;const errors=[],reads=[],hooks={},binding=[],socket={constructTCPSocketServerInstance:()=>server};
 const server={on:(k,f)=>hooks[k]=f,listen:async address=>binding.push(address),getLocalAddress:async()=>({address:'127.0.0.1',port:41001}),close:async()=>closed++};
 const reader={state:()=>({size:1000,downloaded:0}),read:async(o,n,live)=>{reads.push([o,n]);return await read(o,n,live);},close:()=>{closed++;}};
 const mocks={'@kit.NetworkKit':{socket},'@kit.ArkTS':{util:{generateRandomUUID:()=> 'test-token'}},'../model/VideoPlayback':model};
 const js=ts.transpileModule(fs.readFileSync(new URL('../entry/src/main/ets/services/VideoHttpStream.ets',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
 const mod={exports:{}};new Function('require','exports','module',js)(n=>mocks[n],mod.exports,mod);
 const stream=new mod.exports.VideoHttpStream(reader,e=>errors.push(e));let serial=0;
 const connect=()=>{const events={},sent=[];let closed=false;const conn={clientId:++serial,on:(k,f)=>events[k]=f,send:async({data})=>{sent.push(data);},close:async()=>{closed=true;}};hooks.connect(conn);return {events,sent,get closed(){return closed;},request:header=>events.message({message:new TextEncoder().encode(header).buffer})};};
 return {stream,binding,reads,errors,connect,get closed(){return closed;},flush:async()=>{await new Promise(r=>setImmediate(r));await new Promise(r=>setImmediate(r));}};
}
test('HTTP range parsing handles open, bounded, suffix and invalid requests without widening access',()=>{
 const r=model.videoHttpRange;assert.deepEqual(r('',1000),{start:0,end:999,partial:false});assert.deepEqual(r('bytes=100-',1000),{start:100,end:999,partial:true});
 assert.deepEqual(r('bytes=-20',1000),{start:980,end:999,partial:true});assert.deepEqual(r('bytes=100-2000',1000),{start:100,end:999,partial:true});
 for(const v of ['bytes=1000-','bytes=9-8','bytes=-0','bytes=0-1,8-9','bytes=1e3-','bytes=99999999999999999999-','bytes=-'])assert.equal(r(v,1000),undefined);
});
test('video bridge binds only loopback with ephemeral port and rejects an unknown route before reading',async()=>{
 const f=fixture();assert.equal(await f.stream.open(),'http://127.0.0.1:41001/test-token/video.mp4');assert.deepEqual(f.binding,[{address:'127.0.0.1',port:0,family:1}]);
 const c=f.connect();c.request('GET /wrong/video.mp4 HTTP/1.1\r\n\r\n');await f.flush();assert.match(c.sent[0],/404/);assert.equal(f.reads.length,0);assert.equal(c.closed,true);f.stream.close();
});
test('HEAD reports real size and range support without downloading media',async()=>{
 const f=fixture();await f.stream.open();const c=f.connect();c.request('HEAD /test-token/video.mp4 HTTP/1.1\r\n\r\n');await f.flush();assert.match(c.sent[0],/Content-Length: 1000/);assert.match(c.sent[0],/Accept-Ranges: bytes/);assert.equal(c.sent.length,1);assert.equal(f.reads.length,0);f.stream.close();
});
test('seek requests return exact 206 headers and only the requested bytes',async()=>{
 const f=fixture();await f.stream.open();const c=f.connect();c.request('GET /test-token/video.mp4 HTTP/1.1\r\nRange: bytes=100-199\r\n\r\n');await f.flush();
 assert.match(c.sent[0],/206 Partial Content/);assert.match(c.sent[0],/Content-Range: bytes 100-199\/1000/);assert.match(c.sent[0],/Content-Length: 100/);assert.deepEqual(f.reads,[[100,100]]);assert.equal(c.sent[1].byteLength,100);assert.equal(c.closed,true);f.stream.close();
});
test('invalid, multipart and duplicate range headers never trigger a broad download',async()=>{
 const f=fixture();await f.stream.open();for(const header of ['Range: bytes=2000-','Range: bytes=1-2,8-9','Range: bytes=1-2\r\nRange: bytes=2-3']){const c=f.connect();c.request('GET /test-token/video.mp4 HTTP/1.1\r\n'+header+'\r\n\r\n');await f.flush();assert.match(c.sent[0],/(416|400)/);}assert.equal(f.reads.length,0);f.stream.close();
});
test('fragmented TCP headers wait for their terminator and oversized headers are dropped',async()=>{
 const f=fixture();await f.stream.open();const c=f.connect();c.request('HEAD /test-token/video.mp4 HTTP/1.1\r\n');await f.flush();assert.equal(c.sent.length,0);c.request('\r\n');await f.flush();assert.match(c.sent[0],/200 OK/);
 const huge=f.connect();huge.request('A'.repeat(8193));await f.flush();assert.equal(huge.closed,true);f.stream.close();
});
test('a new seek invalidates the previous connection even if its old disk read resolves later',async()=>{
 const pending=[];const f=fixture((o,n)=>new Promise(resolve=>pending.push({o,n,resolve})));await f.stream.open();
 const a=f.connect();a.request('GET /test-token/video.mp4 HTTP/1.1\r\nRange: bytes=0-99\r\n\r\n');await f.flush();
 const b=f.connect();b.request('GET /test-token/video.mp4 HTTP/1.1\r\nRange: bytes=700-799\r\n\r\n');await f.flush();assert.equal(a.closed,true);
 pending[0].resolve(new ArrayBuffer(100));pending[1].resolve(new ArrayBuffer(100));await f.flush();assert.equal(a.sent.length,1);assert.equal(b.sent[1].byteLength,100);f.stream.close();
});
test('disk/network failure surfaces a safe error and close releases sockets, listener and reader',async()=>{
 const f=fixture(async()=>{throw Error('缓冲超时 /PRIVATE/PATH');});await f.stream.open();const c=f.connect();c.request('GET /test-token/video.mp4 HTTP/1.1\r\n\r\n');await f.flush();assert.equal(c.closed,true);assert.equal(f.errors.length,1);assert.doesNotMatch(f.errors[0],/PRIVATE/);f.stream.close();f.stream.close();assert.equal(f.closed,2);
});
