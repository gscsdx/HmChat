import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const ts = require(process.env.HARLGRAM_TYPESCRIPT);
function load(file, mocks) {
 const js = ts.transpileModule(fs.readFileSync(new URL('../entry/src/main/ets/' + file, import.meta.url),'utf8'), { compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS} }).outputText;
 const mod={exports:{}};
 new Function('require','exports','module','setInterval','clearInterval',js)(name=> {if(!(name in mocks))throw Error(name);return mocks[name];},mod.exports,mod,()=>1,()=>{});
 return mod.exports;
}
function fixture() {
 const model=load('model/SessionStorage.ts',{});
 const secondary='a'.repeat(32), entries=new Map([['primary',{apiId:12345,apiHash:'b'.repeat(32),encryptionKey:'legacy-key'}]]);
 let stored={active:'primary',accounts:[{id:'primary',name:'Original'}]}, failSave=false, stuck=false;
 const starts=[]; let closes=0; let instance;
 const fileApi={accessSync:()=>true,access:async()=>false};
 class Client {
  constructor(){instance=this;}
  current={phase:'idle',ready:false};
  state(){return {...this.current};} subscribe(fn){this.listener=fn;fn(this.state());} unsubscribe(){}
  start(p){assert.ok(['idle','closed'].includes(this.current.phase));starts.push(p);this.current={phase:'phone',ready:false};this.listener?.(this.state());}
  close(){closes++;if(!stuck){this.current={phase:'closed',ready:false};this.listener?.(this.state());}}
  leaveChat(){} drain(){} getCurrentUser(){return this.current.ready ? (this.user || {id:'42',name:'New example account'}) : undefined;} fail(){}
 }
 const vault={load:async id=>entries.get(id),createAccountId:()=>secondary, save:async(id,hash,fresh,account)=>{const p=entries.get(account)||{apiId:id,apiHash:hash,encryptionKey:'new-key',databaseNamespace:secondary};entries.set(account,p);return p;}};
 const store={load:async()=>structuredClone(stored),save:async value=>{if(failSave)throw Error('fixture');stored=structuredClone(value);}};
 const service=load('services/TelegramService.ets',{
  '@kit.CoreFileKit':{fileIo:fileApi},'@kit.BasicServicesKit':{},'libentry.so':{default:{getTdlibStatus:()=> 'available'}},
  '../data/ChatRepository':{chatRepository:{}},'../model/VideoPlayback':{VideoRangeReader:class {constructor(source){this.source=source;}}},'../telegram/TelegramClient':{TelegramClient:Client},'./CredentialVault':{CredentialVault:vault},'./AttachmentService':{},'./StorageManager':{StorageManager:class {async initialize(){} foreground(){} async maintain(){}}},
  '../telegram/TdTypes':{},'../model/SessionStorage':model,'./AccountStore':{AccountStore:store},'../config/TelegramBuildConfig':{TELEGRAM_API_ID:12345,TELEGRAM_API_HASH:'b'.repeat(32),TELEGRAM_API_PRESETS:[{id:12345,hash:'b'.repeat(32),label:''}]},
  './LoginApiPreferences':{LoginApiPreferences:{load:async()=>0,save:async()=>{}}}
 }).telegramService;
 return {service,fileApi,authorize:(user)=>{instance.user=user;instance.current={phase:'ready',ready:true};instance.listener?.(instance.state());},context:{filesDir:'/fixture'},starts,entries,secondary,get stored(){return stored;},get closes(){return closes;},set failSave(v){failSave=v;}};
}
test('adding an account closes but never logs out or overwrites legacy credentials',async()=>{
 const f=fixture();await f.service.resume(f.context);const original=structuredClone(f.entries.get('primary'));
 await f.service.addAccount(f.context);
 assert.equal(f.closes,1);assert.deepEqual(f.entries.get('primary'),original);
 assert.equal(f.starts[0].databaseDirectory,'/fixture/telegram');
 assert.equal(f.starts[1].databaseDirectory,'/fixture/telegram/session-'+f.secondary);
 assert.notEqual(f.starts[0].encryptionKey,f.starts[1].encryptionKey);
 assert.equal(f.stored.active,f.secondary);
});
test('switching back restores the original key and original database path',async()=>{
 const f=fixture();await f.service.resume(f.context);await f.service.addAccount(f.context);await f.service.switchAccount(f.context,'primary');
 assert.equal(f.starts.at(-1).databaseDirectory,'/fixture/telegram');assert.equal(f.starts.at(-1).encryptionKey,'legacy-key');
 assert.equal(f.stored.active,'primary');assert.equal(f.entries.size,2);
});
test('an unfinished login is reused without appearing in the account list',async()=>{
 const f=fixture();await f.service.resume(f.context);await f.service.addAccount(f.context);await f.service.switchAccount(f.context,'primary');await f.service.addAccount(f.context);
 assert.equal(f.service.accounts().length,1);assert.equal(f.service.activeAccount(),f.secondary);
});
test('unknown account selection leaves the active connection and credentials untouched',async()=>{
 const f=fixture();await f.service.resume(f.context);await assert.rejects(f.service.switchAccount(f.context,'missing'));
 assert.equal(f.closes,0);assert.equal(f.starts.length,1);assert.equal(f.service.activeAccount(),'primary');
});
test('registry write failure never connects a new account or changes existing credentials',async()=>{
 const f=fixture();await f.service.resume(f.context);f.failSave=true;await assert.rejects(f.service.addAccount(f.context));
 assert.equal(f.service.activeAccount(),'primary');assert.equal(f.entries.size,1);assert.equal(f.starts.length,1);
});

test('concurrent add requests create only one new account connection',async()=>{
 const f=fixture();await f.service.resume(f.context);
 const results=await Promise.allSettled([f.service.addAccount(f.context),f.service.addAccount(f.context)]);
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 assert.equal(f.service.accounts().length,1);assert.equal(f.closes,1);assert.equal(f.starts.length,2);
});

test('only an authenticated user is promoted from pending login to the account list', async()=>{
 const f=fixture();f.service.subscribe(()=>{});await f.service.resume(f.context);await f.service.addAccount(f.context);
 assert.equal(f.service.accounts().length,1);assert.equal(f.stored.pending,f.secondary);
 f.authorize();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.service.accounts().length,2);assert.equal(f.stored.pending,undefined);
 assert.equal(f.service.accounts()[1].name,'New example account');
});

function registryFixture(value){
 return load('services/AccountStore.ets',{
  '@kit.AssetStoreKit':{asset:{Tag:{ALIAS:1,RETURN_TYPE:2,SECRET:3},ReturnType:{ALL:1},query:async()=>[{get:()=>new TextEncoder().encode(JSON.stringify(value))}]}},
  '@kit.ArkTS':{util:{TextEncoder:class {encodeInto(s){return new TextEncoder().encode(s);}},TextDecoder:class {decodeToString(b){return new TextDecoder().decode(b);}}}}
 }).AccountStore;
}
test('legacy failed login entries migrate out of visible accounts without changing active storage identity',async()=>{
 const id='a'.repeat(32);const store=registryFixture({active:id,accounts:[{id:'primary',name:'Original'},{id,name:'未登录账户'}]});
 const result=await store.load();assert.equal(result.accounts.length,1);assert.equal(result.pending,id);assert.equal(result.active,id);
});
test('a legitimately authenticated name is never treated as a placeholder in new registries',async()=>{
 const store=registryFixture({version:2,active:'primary',accounts:[{id:'primary',name:'未登录账户'}]});
 const result=await store.load();assert.equal(result.accounts.length,1);assert.equal(result.pending,undefined);
});

test('account avatars remain associated with their own account after switching',async()=>{
 const f=fixture();f.service.subscribe(()=>{});await f.service.resume(f.context);
 f.authorize({id:'1',name:'Original',avatar:'O',color:'#123456',avatarFileId:9,avatarPath:'/fixture/primary/avatar.jpg'});
 await f.service.addAccount(f.context);
 f.authorize({id:'2',name:'Other',avatar:'N',color:'#654321',avatarFileId:10,avatarPath:'/fixture/secondary/avatar.jpg'});
 await new Promise(resolve=>setImmediate(resolve));
 const accounts=f.service.accounts();assert.equal(accounts[0].avatarPath,'/fixture/primary/avatar.jpg');assert.equal(accounts[1].avatarPath,'/fixture/secondary/avatar.jpg');
 await f.service.switchAccount(f.context,'primary');
 assert.equal(f.service.accounts()[1].avatarPath,'/fixture/secondary/avatar.jpg');
 assert.equal(f.stored.accounts[0].avatarPath,'/fixture/primary/avatar.jpg');
});

test('a missing partial cache path is revalidated through TDLib before the video reader starts',async()=>{
 const f=fixture();await f.service.resume(f.context);f.authorize();const calls=[];
 f.service.client.videoFile=()=>({size:10000000,local:{path:'/fixture/removed',downloaded_size:5000000,is_downloading_completed:false}});
 f.service.client.videoRange=async(...args)=>calls.push(args);
 const reader=await f.service.createVideoReader('-10','1',80);assert.deepEqual(calls,[[80,0,2097152]]);assert.equal(reader.source.current(),true);
 await f.service.addAccount(f.context);assert.equal(reader.source.current(),false);
});
test('account change during disk validation never starts a download in the new account',async()=>{
 const f=fixture();await f.service.resume(f.context);f.authorize();let finish;const calls=[];
 f.fileApi.access=()=>new Promise(resolve=>finish=resolve);
 f.service.client.videoFile=()=>({size:10000000,local:{path:'/fixture/old',downloaded_size:1,is_downloading_completed:false}});
 f.service.client.videoRange=async(...args)=>calls.push(args);
 const reader=f.service.createVideoReader('-10','1',80);await f.service.addAccount(f.context);finish(false);
 await assert.rejects(reader,/账户已切换/);assert.equal(calls.length,0);
});
