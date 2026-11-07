import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require=createRequire(import.meta.url);
const model=require('../artifacts/tests/js/model/VideoPlayback.js');
const {VideoRangeReader,videoWindow,VIDEO_WINDOW,VIDEO_CHUNK,seekPosition}=model;
function fixture(){
 let state={path:'/fixture/video',size:10*1024**2,downloaded:0,complete:false},current=true,prefix=0,waiting,reads=[],downloads=[],cancelled=0;
 const reader=new VideoRangeReader({state:()=>state,current:()=>current,prefix:async()=>prefix,download:async w=>{downloads.push(w);},read:async(path,offset,length)=>{reads.push({path,offset,length});return new ArrayBuffer(length);},cancel:()=>cancelled++},async()=>{if(waiting)await waiting();else prefix=VIDEO_CHUNK;});
 return {reader,reads,downloads,get cancelled(){return cancelled;},set state(v){state=v;},set current(v){current=v;},set prefix(v){prefix=v;},set wait(v){waiting=v;}};
}
test('video positions clamp rewind/forward and invalid values to the actual duration',()=>{
 assert.equal(seekPosition(-30000,150000),0);assert.equal(seekPosition(180000,150000),149999);assert.equal(seekPosition(45000,150000),45000);
 assert.equal(seekPosition(Infinity,150000),0);assert.equal(seekPosition(100,0),0);
});
test('seek download windows are aligned, bounded and truncated at EOF',()=>{
 assert.deepEqual(videoWindow(3*1024**2+100,10*1024**2),{offset:3*1024**2,limit:VIDEO_WINDOW});
 assert.deepEqual(videoWindow(999,1000),{offset:0,limit:1000});assert.throws(()=>videoWindow(1000,1000));assert.throws(()=>videoWindow(-1,1000));
});
test('a sparse file cannot be read until TDLib confirms contiguous bytes at the requested offset',async()=>{
 const f=fixture();const b=await f.reader.read(5*1024**2,100000,()=>true);
 assert.equal(b.byteLength,VIDEO_CHUNK);assert.equal(f.downloads.length,1);assert.equal(f.downloads[0].offset,5*1024**2);assert.equal(f.reads[0].offset,5*1024**2);
});
test('completed files and cached sparse ranges do not initiate redundant downloads',async()=>{
 const f=fixture();f.prefix=1000;assert.equal((await f.reader.read(9000,2000,()=>true)).byteLength,1000);assert.equal(f.downloads.length,0);
 f.state={path:'/fixture/complete',size:10000,downloaded:10000,complete:true};assert.equal((await f.reader.read(9990,100,()=>true)).byteLength,10);assert.equal((await f.reader.read(10000,100,()=>true)).byteLength,0);
});
test('account changes and superseded seek reads cannot read local data after asynchronous prefix checks',async()=>{
 const f=fixture();let live=true;f.wait=async()=>{live=false;};await assert.rejects(f.reader.read(1,100,()=>live),/取消/);assert.equal(f.reads.length,0);
 const next=fixture();next.wait=async()=>{next.current=false;};await assert.rejects(next.reader.read(1,100,()=>true),/取消/);assert.equal(next.reads.length,0);next.reader.close();assert.equal(next.cancelled,0);
});
test('closing a video cancels its own demand download once and rejects further reads',async()=>{
 const f=fixture();f.reader.close();f.reader.close();assert.equal(f.cancelled,1);await assert.rejects(f.reader.read(0,10,()=>true),/取消/);
});
test('a stalled stream times out rather than returning zero-filled sparse data',async()=>{
 const f=fixture(),now=Date.now;let clock=0;Date.now=()=>clock;f.wait=async()=>{clock+=31000;};
 try{await assert.rejects(f.reader.read(0,10,()=>true),/超时/);assert.equal(f.reads.length,0);}finally{Date.now=now;}
});
const {TelegramClient}=require('../artifacts/tests/js/telegram/TelegramClient.js');
const {ChatRepository}=require('../artifacts/tests/js/data/ChatRepository.js');
function protocolFixture(){
 const sent=[],queue=[],repository=new ChatRepository();const client=new TelegramClient({createClient:()=>9,send:(_,s)=>sent.push(JSON.parse(s)),receive:()=>queue.shift()||''},repository);
 client.start({apiId:123456,apiHash:'0'.repeat(32),databaseDirectory:'/fixture/db',filesDirectory:'/fixture/files',encryptionKey:'fixture'});
 const push=e=>{queue.push(JSON.stringify({'@client_id':9,...e}));client.drain();};push({'@type':'updateAuthorizationState',authorization_state:{'@type':'authorizationStateReady'}});
 push({'@type':'updateNewChat',chat:{'@type':'chat',id:-10,title:'Fixture',type:{'@type':'chatTypeBasicGroup',basic_group_id:5},positions:[],unread_count:0,notification_settings:{mute_for:0}}});client.openChat('-10');
 const file={'@type':'file',id:80,size:10*1024**2,expected_size:10*1024**2,local:{path:'/fixture/partial',can_be_downloaded:true,is_downloading_active:false,is_downloading_completed:false,downloaded_size:1}};
 push({'@type':'updateNewMessage',message:{'@type':'message',id:1,chat_id:-10,date:1700000000,is_outgoing:false,content:{'@type':'messageVideo',video:{video:file,duration:150,width:960,height:540},caption:{'@type':'formattedText',text:''}}}});
 return {client,repository,file,sent,push,last:t=>sent.filter(r=>r['@type']===t).at(-1)};
}
test('streaming validates active-chat/video ownership and never starts an implicit whole-file download',async()=>{
 const f=protocolFixture();assert.equal(f.last('downloadFile'),undefined);assert.throws(()=>f.client.videoFile('-11','1',80));assert.throws(()=>f.client.videoFile('-10','1',81));
 assert.equal(f.client.videoFile('-10','1',80).id,80);const prefix=f.client.videoPrefix(80,5000000),r=f.last('getFileDownloadedPrefixSize');assert.equal(r.offset,5000000);
 f.push({'@type':'fileDownloadedPrefixSize','@extra':r['@extra'],size:65536});assert.equal(await prefix,65536);
 const result=f.client.videoRange(80,5*1024**2,VIDEO_WINDOW),download=f.last('downloadFile');
 assert.equal(download.offset,5*1024**2);assert.equal(download.limit,VIDEO_WINDOW);assert.equal(download.priority,32);assert.equal(download.synchronous,false);
 f.push({...f.file,'@extra':download['@extra'],local:{...f.file.local,downloaded_size:65536,download_offset:5*1024**2,downloaded_prefix_size:65536}});await result;
 f.client.stopVideoRange(80);assert.equal(f.last('cancelDownloadFile').file_id,80);await assert.rejects(f.client.videoPrefix(80,0),/关闭/);
 f.client.leaveChat();assert.throws(()=>f.client.videoFile('-10','1',80));
});
test('closing a stream preserves an earlier explicit full-file download',()=>{
 const f=protocolFixture();f.client.downloadMedia('-10','1');f.push({'@type':'updateFile',file:{...f.file,local:{...f.file.local,is_downloading_active:true}}});
 f.client.videoFile('-10','1',80);f.client.stopVideoRange(80);assert.equal(f.last('downloadFile').offset,0);assert.equal(f.last('downloadFile').priority,16);assert.equal(f.last('cancelDownloadFile'),undefined);
});

test('a download reply resolved just before Closed cannot repopulate the next account file cache',async()=>{
 const f=protocolFixture();f.client.videoFile('-10','1',80);const result=f.client.videoRange(80,0,VIDEO_WINDOW),request=f.last('downloadFile');
 f.push({...f.file,'@extra':request['@extra']});f.push({'@type':'updateAuthorizationState',authorization_state:{'@type':'authorizationStateClosed'}});
 await assert.rejects(result,/连接已改变/);assert.throws(()=>f.client.videoFile('-10','1',80));
});


test('rapid timeline requests perform one native seek followed by only the latest target',()=>{
 const q=new model.VideoSeekQueue();assert.equal(q.request(30000),30000);assert.equal(q.request(0),undefined);assert.equal(q.request(120000),undefined);
 assert.equal(q.complete(),120000);assert.equal(q.pending(),true);assert.equal(q.complete(),undefined);assert.equal(q.pending(),false);
 assert.equal(q.request(0),0);q.reset();assert.equal(q.pending(),false);assert.equal(q.request(8000),8000);
});



test('a fully evicted video starts a range download without querying a nonexistent local prefix',async()=>{
 const f=protocolFixture();f.push({'@type':'updateFile',file:{...f.file,local:{...f.file.local,path:'',downloaded_size:0}}});f.client.videoFile('-10','1',80);
 assert.equal(await f.client.videoPrefix(80,0),0);assert.equal(f.last('getFileDownloadedPrefixSize'),undefined);
 const download=f.client.videoRange(80,0,VIDEO_WINDOW),r=f.last('downloadFile');assert.equal(r.offset,0);f.push({...f.file,'@extra':r['@extra']});await download;
});
