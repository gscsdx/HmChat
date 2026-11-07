import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const model = require('../artifacts/tests/js/model/StorageModels.js');
const { TelegramClient } = require('../artifacts/tests/js/telegram/TelegramClient.js');
const { ChatRepository } = require('../artifacts/tests/js/data/ChatRepository.js');
const ts = require(process.env.HARLGRAM_TYPESCRIPT);
const params = { apiId: 123456, apiHash: '0'.repeat(32), databaseDirectory: '/fixture/db', filesDirectory: '/fixture/files', encryptionKey: 'fixture' };
function clientFixture() {
 const sent=[],queue=[];
 const client=new TelegramClient({createClient:()=>9,send:(_,raw)=>sent.push(JSON.parse(raw)),receive:()=>queue.shift()||''},new ChatRepository());
 client.start(params);
 const push=e=>{queue.push(JSON.stringify({'@client_id':9,...e}));client.drain();};
 push({'@type':'updateAuthorizationState',authorization_state:{'@type':'authorizationStateReady'}});
 return {client,sent,push,last:type=>sent.filter(r=>r['@type']===type).at(-1)};
}
test('storage categories keep unknown, secure and secret files outside selectable media',()=>{
 const categories=model.storageCategories({size:600,count:6,by_chat:[{chat_id:1,by_file_type:[
  {file_type:{'@type':'fileTypePhoto'},size:100,count:1},{file_type:{'@type':'fileTypeVideo'},size:200,count:2},
  {file_type:{'@type':'fileTypeSecret'},size:100,count:1},{file_type:{'@type':'fileTypeSecure'},size:100,count:1},
  {file_type:{'@type':'fileTypeFuture'},size:100,count:1}]}]});
 assert.equal(categories.find(c=>c.id==='protected').bytes,300);
 assert.equal(categories.reduce((s,c)=>s+c.bytes,0),600);
 assert.equal(categories.find(c=>c.id==='protected').cleanable,false);
 assert.deepEqual(model.selectedCacheTypes(['protected','fileTypeSecret','bogus']),[]);
});
test('explicit cache deletion never expands an empty selection or activates TDLib default limits',()=>{
 assert.equal(model.clearCacheCommand([]),undefined);
 assert.equal(model.clearCacheCommand(['protected']),undefined);
 assert.equal(model.clearCacheCommand(['photo'],[NaN]),undefined);
 const c=model.clearCacheCommand(['video'],[-10001],[42]);
 assert.deepEqual(c.file_types,[{'@type':'fileTypeVideo'},{'@type':'fileTypeVideoNote'}]);
 assert.deepEqual([c.size,c.ttl,c.count,c.immunity_delay],[0,0,0,0]);
 assert.deepEqual(c.chat_ids,[-10001]);assert.deepEqual(c.exclude_chat_ids,[42]);
 assert.equal(c.return_deleted_file_statistics,true);
});
test('network policies deny unknown sizes, roaming and automatic video by default; manual limits remain separate',()=>{
 const p=model.defaultMediaPolicy();assert.equal(model.validMediaPolicy(p),true);
 for(const network of ['unknown','none','roaming'])assert.equal(model.autoDownloadAllowed(p,network,'photo',100),false);
 for(const bytes of [0,-1,NaN,Infinity,1.5])assert.equal(model.autoDownloadAllowed(p,'wifi','photo',bytes),false);
 assert.equal(model.autoDownloadAllowed(p,'wifi','photo',2*1024**2),true);
 assert.equal(model.autoDownloadAllowed(p,'mobile','photo',2*1024**2),false);
 assert.equal(model.autoDownloadAllowed(p,'wifi','video',100),false);
 const copy=model.cloneMediaPolicy(p);copy.wifi.enabled=false;assert.equal(p.wifi.enabled,true);
 copy.privateDays=-1;assert.equal(model.validMediaPolicy(copy),false);
 copy.privateDays=0;copy.wifi.photoLimit=0;assert.equal(model.validMediaPolicy(copy),false);
});
test('storage requests correlate out-of-order replies, keep errors out of authentication, and fail closed after disconnect',async()=>{
 const f=clientFixture(),a=f.client.storageStatistics(),ar=f.last('getStorageStatistics'),b=f.client.networkStatistics(),br=f.last('getNetworkStatistics');
 f.push({'@type':'networkStatistics','@extra':br['@extra'],since_date:10,entries:[]});
 f.push({'@type':'storageStatistics','@extra':ar['@extra'],size:123,count:1,by_chat:[]});
 assert.equal((await a).size,123);assert.equal((await b).since_date,10);
 const failure=f.client.fastStorageStatistics(),fr=f.last('getStorageStatisticsFast');
 f.push({'@type':'error','@extra':fr['@extra'],code:500,message:'PRIVATE_ERROR'});
 await assert.rejects(failure,/操作未完成/);assert.equal(f.client.state().ready,true);
 const pending=f.client.storageStatistics();f.push({'@type':'updateAuthorizationState',authorization_state:{'@type':'authorizationStateClosed'}});
 await assert.rejects(pending,/关闭/);await assert.rejects(f.client.storageStatistics(),/登录/);
});
test('storage timeout settles once and late replies cannot change authentication',async()=>{
 const f=clientFixture(),promise=f.client.storageStatistics(),request=f.last('getStorageStatistics');
 const now=Date.now;try {Date.now=()=>now()+31000;f.client.drain();}finally{Date.now=now;}
 await assert.rejects(promise,/超时/);
 f.push({'@type':'error','@extra':request['@extra'],code:401,message:'late'});
 assert.equal(f.client.state().ready,true);
});
function managerFixture() {
 const stores=new Map(),commands=[],configurations=[];let protectedChats=[99],deferred;
 const usage={size:500,count:3,by_chat:[{chat_id:1,size:100,by_file_type:[]},{chat_id:-2,size:200,by_file_type:[]},{chat_id:0,size:200,by_file_type:[]}]};
 const client={state:()=>({ready:true}),configureMediaPolicy:(p,n)=>configurations.push([p,n]),setMediaNetwork:()=>{},
  storageStatistics:async()=>usage,fastStorageStatistics:async()=>({database_size:4,language_pack_database_size:2,log_size:1}),
  storageChat:async id=>({title:'Fixture',type:{'@type':id===1?'chatTypePrivate':'chatTypeSupergroup',is_channel:false}}),isSavedStorageChat:()=>false,
  protectedCacheChats:()=>protectedChats,optimizeCache:async command=>{commands.push(command);return deferred?await deferred:{size:77};}};
 const mocks={ '@kit.ArkData':{preferences:{getPreferences:async(_,{name})=>{if(!stores.has(name))stores.set(name,new Map());const map=stores.get(name);return {get:async(k,d)=>map.get(k)??d,put:async(k,v)=>map.set(k,v),flush:async()=>{}};}}},
 '@kit.CoreFileKit':{fileIo:{access:async()=>false},statfs:{getTotalSize:async()=>10000,getFreeSize:async()=>5000}},
 './MediaNetworkMonitor':{MediaNetworkMonitor:class {start(){}}},'../model/StorageModels':model};
 const js=ts.transpileModule(fs.readFileSync(new URL('../entry/src/main/ets/services/StorageManager.ets',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
 const mod={exports:{}};new Function('require','exports','module',js)(n=>{if(!(n in mocks))throw Error(n);return mocks[n];},mod.exports,mod);
 const manager=new mod.exports.StorageManager(client);
 return {manager,commands,stores,context:{filesDir:'/fixture',cacheDir:'/fixture/cache'},set deferred(v){deferred=v;}};
}
test('maintenance TTL is scoped by chat kind and never sweeps unowned, current or pending media',async()=>{
 const f=managerFixture();await f.manager.initialize(f.context,'primary');
 const p=f.manager.settings();p.privateDays=7;p.groupDays=30;await f.manager.savePolicy(p);await f.manager.maintain(true);
 assert.equal(f.commands.length,2);
 for(const c of f.commands){assert.equal(c.size,model.MAX_STORAGE_BYTES);assert.equal(c.count,model.MAX_STORAGE_AGE);assert.deepEqual(c.exclude_chat_ids,[99]);assert.equal(c.immunity_delay,3600);assert.ok(c.file_types.length);assert.ok(!c.chat_ids.includes(0));}
 assert.deepEqual(f.commands.map(c=>[c.ttl,c.chat_ids]),[[7*86400,[1]],[30*86400,[-2]]]);
});
test('cache caps preserve unowned media and avoid implicit age/count cleanup',async()=>{
 const f=managerFixture();await f.manager.initialize(f.context,'primary');
 const p=f.manager.settings();p.cacheLimit=1024**3;await f.manager.savePolicy(p);
 // Override statistics to represent a cache above the selected cap.
 f.manager.client.storageStatistics=async()=>({size:2*1024**3,count:1,by_chat:[]});
 await f.manager.maintain(true);const c=f.commands[0];
 assert.equal(c.size,1024**3);assert.equal(c.ttl,model.MAX_STORAGE_AGE);assert.equal(c.count,model.MAX_STORAGE_AGE);assert.deepEqual(c.exclude_chat_ids,[0,99]);
});
test('preferences are isolated per account; manual clear reports real freed bytes without touching storage paths',async()=>{
 const f=managerFixture();await f.manager.initialize(f.context,'primary');
 const p=f.manager.settings();p.wifi.videos=true;await f.manager.savePolicy(p);
 assert.equal(await f.manager.clear(['video'],[-2]),77);assert.equal(f.manager.isBusy(),false);
 assert.deepEqual(f.commands[0].chat_ids,[-2]);assert.deepEqual(f.commands[0].exclude_chat_ids,[99]);
 await f.manager.initialize(f.context,'secondary');assert.equal(f.manager.settings().wifi.videos,false);
 await f.manager.initialize(f.context,'primary');assert.equal(f.manager.settings().wifi.videos,true);
});
test('account switching invalidates an old clear response without releasing a new account operation',async()=>{
 const f=managerFixture();await f.manager.initialize(f.context,'primary');let finish;
 f.deferred=new Promise(resolve=>finish=resolve);const old=f.manager.clear(['photo']);
 await f.manager.initialize(f.context,'secondary');let finishNew;f.deferred=new Promise(resolve=>finishNew=resolve);const next=f.manager.clear(['photo']);
 finish({size:1});await assert.rejects(old,/切换/);assert.equal(f.manager.isBusy(),true);
 finishNew({size:2});assert.equal(await next,2);assert.equal(f.manager.isBusy(),false);
});
function addPhoto(f,chatId,id,fileId,local={}) {
 f.push({'@type':'updateNewChat',chat:{'@type':'chat',id:chatId,title:'Fixture',type:{'@type':'chatTypeSupergroup',supergroup_id:5,is_channel:false},positions:[{list:{'@type':'chatListMain'},order:'100',is_pinned:false}],notification_settings:{mute_for:0},unread_count:0}});
 f.client.openChat(String(chatId));
 f.push({'@type':'updateNewMessage',message:{'@type':'message',id,chat_id:chatId,date:1700000000,is_outgoing:false,
 content:{'@type':'messagePhoto',photo:{sizes:[{type:'m',width:100,height:100,photo:{'@type':'file',id:fileId,size:10000,expected_size:10000,local:{path:'',can_be_downloaded:true,is_downloading_active:false,is_downloading_completed:false,...local}}}]},caption:{'@type':'formattedText',text:''}}}});
}
test('a network policy change resumes eligible photos in negative-id group chats only',()=>{
 const f=clientFixture();addPhoto(f,-100,1,61);assert.equal(f.last('downloadFile'),undefined);
 f.client.setMediaNetwork('wifi');assert.equal(f.last('downloadFile').file_id,61);
 f.client.leaveChat();const before=f.sent.filter(r=>r['@type']==='downloadFile').length;
 f.client.setMediaNetwork('wifi');assert.equal(f.sent.filter(r=>r['@type']==='downloadFile').length,before);
});
test('cache GC re-reads file state and invalidates stale media paths without deleting cloud messages',async()=>{
 const f=clientFixture();addPhoto(f,-100,1,62,{path:'/fixture/cached.jpg',is_downloading_completed:true});
 const c=model.clearCacheCommand(['photo']);const done=f.client.optimizeCache(c),r=f.last('optimizeStorage');
 f.push({'@type':'storageStatistics','@extra':r['@extra'],size:10000,count:1,by_chat:[]});
 assert.equal((await done).size,10000);assert.equal(f.last('getFile').file_id,62);
 assert.equal(f.sent.some(r=>['logOut','deleteMessages','deleteChatHistory','destroy'].includes(r['@type'])),false);
 f.push({'@type':'updateFile',file:{'@type':'file',id:62,size:10000,expected_size:10000,local:{path:'',can_be_downloaded:true,is_downloading_active:false,is_downloading_completed:false}}});
 // No immediate automatic re-download is scheduled by a GC file update.
 assert.equal(f.last('downloadFile'),undefined);
});
test('secret chats and unknown chat kinds are excluded from automatic maintenance',async()=>{
 const f=managerFixture();await f.manager.initialize(f.context,'primary');
 f.manager.client.storageChat=async id=>({title:'Fixture',type:{'@type':id===1?'chatTypeSecret':'chatTypeFuture'}});
 const p=f.manager.settings();p.privateDays=1;p.groupDays=1;p.cacheLimit=1024**3;await f.manager.savePolicy(p);
 f.manager.client.storageStatistics=async()=>({size:2*1024**3,count:1,by_chat:[{chat_id:1,size:100},{chat_id:-2,size:100}]});
 await f.manager.maintain(true);assert.equal(f.commands.length,1);assert.deepEqual(f.commands[0].exclude_chat_ids,[0,1,-2,99]);
 const c=clientFixture();c.push({'@type':'updateNewChat',chat:{'@type':'chat',id:19,title:'Fixture',type:{'@type':'chatTypeSecret',secret_chat_id:1,user_id:2},positions:[],notification_settings:{mute_for:0},unread_count:0}});
 assert.ok(c.client.protectedCacheChats().includes(19));
});
