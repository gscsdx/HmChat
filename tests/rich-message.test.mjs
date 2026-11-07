import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { decodeRichText, decodeRichBlocks } = require('../artifacts/tests/js/telegram/RichMessage.js');
const { messageRuns, concealedMessageText } = require('../artifacts/tests/js/model/MessagePresentation.js');
const plain = text => ({'@type':'richTextPlain',text});
const parent={id:'10',chatId:'101',text:'',time:'12:00',status:'received',outgoing:false};

test('RichText recursive formatting keeps UTF-16 offsets and spoiler protections',()=>{
 const value=decodeRichText({'@type':'richTexts',texts:[plain('😀 '),{'@type':'richTextBold',text:{'@type':'richTextUrl',url:'https://example.org',text:plain('Link')}},plain(' '),{'@type':'richTextSpoiler',text:plain('secret')}]});
 assert.equal(value.text,'😀 Link secret');
 assert.ok(messageRuns(value.text,value.entities).some(x=>x.text==='Link'&&x.bold&&x.link==='https://example.org'));
 assert.equal(concealedMessageText(value.text,value.entities),'😀 Link ••••••');
});
test('rich message paragraphs, headings, lists, quotes and code retain content instead of a generic placeholder',()=>{
 const result=decodeRichBlocks([
  {'@type':'pageBlockTitle',title:plain('Heading')},
  {'@type':'pageBlockParagraph',text:plain('Intro')},
  {'@type':'pageBlockList',items:[{label:'1.',blocks:[{'@type':'pageBlockParagraph',text:{'@type':'richTextBold',text:plain('First')}}]}]},
  {'@type':'pageBlockBlockQuote',blocks:[{'@type':'pageBlockParagraph',text:plain('Quoted')}]},
  {'@type':'pageBlockPreformatted',text:plain('  const a = 1;\n  next();')}
 ],parent);
 assert.deepEqual(result.map(x=>x.block.kind),['heading','text','text','quote','code']);
 assert.equal(result[2].block.text,'1. First'); assert.equal(result[2].block.entities[0].offset,3);
 assert.ok(result[3].block.entities.some(x=>x.type==='textEntityTypeBlockQuote'));
 assert.equal(result[4].block.text,'  const a = 1;\n  next();');
});
test('embedded rich media keep source message identity and never reveal spoiler files',()=>{
 const file={id:90,size:100,expected_size:100,local:{path:'/fixture/photo.jpg',is_downloading_completed:true,can_be_downloaded:true,is_downloading_active:false}};
 const block={'@type':'pageBlockPhoto',photo:{sizes:[{width:640,height:480,photo:file}]},caption:{text:plain('Caption'),credit:plain('')}};
 const result=decodeRichBlocks([block,{...block,has_spoiler:true}],parent);
 assert.equal(result[0].block.media.sourceMessageId,'10'); assert.equal(result[0].block.media.id,'10:rich:0');
 assert.equal(result[0].block.media.mediaFileId,90);assert.equal(result[1].file,undefined);
 assert.equal(result[1].block.text,'[剧透媒体]');
});
test('rich message rendering bounds recursive trees and output block counts',()=>{
 let node=plain('bottom');for(let i=0;i<40;i++)node={'@type':'richTextBold',text:node};
 assert.equal(decodeRichText(node).text,'');
 assert.equal(decodeRichBlocks(Array.from({length:500},()=>({'@type':'pageBlockParagraph',text:plain('fixture')})),parent).length,200);
});
