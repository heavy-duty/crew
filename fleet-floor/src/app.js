"use strict";
(function(){
/* ============================================================
   Fleet Floor — pixel god-view of heavy-duty/crew (simulated feed)
   World is drawn to a small offscreen "art" buffer then blitted
   nearest-neighbour, so pixels stay crisp at any screen size.
   ============================================================ */

var TILE = 8, COLS = 66, ROWS = 42;
var W = COLS*TILE, H = ROWS*TILE;               // 528 x 336 art px
var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

var VENDOR = { claude:"#f6a04d", codex:"#3ad6a4", grok:"#b07cff", kimi:"#ff72b6" };
var STATE = {
  building:{c:"#f5b743", label:"Building",     kind:"build"},
  reviewing:{c:"#57b0ff", label:"Reviewing",   kind:"review"},
  triaging:{c:"#c98bff", label:"Triaging",     kind:"triage"},
  idle:{c:"#63c896",      label:"Idle",         kind:"idle"},
  dead:{c:"#ff5c5c",      label:"Disconnected", kind:"dead"}
};

// zone rect as [col0,row0,col1,row1] (inclusive tiles)
var OFFICE = {c0:24,r0:2,c1:41,r1:12};
var BOXDEFS = [
  {id:"claude-triage",  agent:"claude", role:"triage",   z:[2,2,19,13],  repos:["ceremony","box","crew"]},
  {id:"claude-builder", agent:"claude", role:"builder",  z:[2,15,19,26], repos:["incubator","ceremony","box"]},
  {id:"claude-reviewer",agent:"claude", role:"reviewer", z:[2,28,19,39], repos:["cast","rig","ceremony"]},
  {id:"codex-builder",  agent:"codex",  role:"builder",  z:[24,16,41,27],repos:["box","incubator","crew"]},
  {id:"codex-reviewer", agent:"codex",  role:"reviewer", z:[24,29,41,39],repos:["ceremony","cast"]},
  {id:"grok-reviewer",  agent:"grok",   role:"reviewer", z:[46,2,63,13], repos:["rig","ceremony","incubator"]},
  {id:"kimi-reviewer",  agent:"kimi",   role:"reviewer", z:[46,15,63,26],repos:["cast","box","ceremony"]}
];

/* ---------- small utils ---------- */
function rnd(a,b){ return a + Math.random()*(b-a); }
function ri(a,b){ return Math.floor(rnd(a,b+1)); }
function pick(arr){ return arr[ri(0,arr.length-1)]; }
function chance(p){ return Math.random() < p; }
function clamp(v,a,b){ return v<a?a:(v>b?b:v); }
function hex(h){ h=h.replace("#",""); return [parseInt(h.substr(0,2),16),parseInt(h.substr(2,2),16),parseInt(h.substr(4,2),16)]; }
function shade(h,f){ // f<1 darken, >1 lighten toward white
  var c=hex(h), r,g,b;
  if(f<=1){ r=c[0]*f; g=c[1]*f; b=c[2]*f; }
  else { var t=f-1; r=c[0]+(255-c[0])*t; g=c[1]+(255-c[1])*t; b=c[2]+(255-c[2])*t; }
  return "rgb("+Math.round(clamp(r,0,255))+","+Math.round(clamp(g,0,255))+","+Math.round(clamp(b,0,255))+")";
}
function pad(n){ return (n<10?"0":"")+n; }
function nowClock(){ var d=new Date(); return pad(d.getUTCHours())+":"+pad(d.getUTCMinutes())+":"+pad(d.getUTCSeconds()); }
function issueKey(repo){ return repo+"#"+ri(11,148); }

/* ---------- build runtime boxes ---------- */
var boxes = BOXDEFS.map(function(d,i){
  var z=d.z, cx=(z[0]+z[2]+1)/2, home={x:cx*TILE, y:(z[1]+5)*TILE};
  var b = {
    idx:i, id:d.id, agent:d.agent, role:d.role, repos:d.repos,
    color:VENDOR[d.agent], zone:{c0:z[0],r0:z[1],c1:z[2],r1:z[3]},
    home:home, x:home.x, y:home.y, tx:home.x, ty:home.y,
    face:1, phase:Math.random()*10, walkT:0,
    state:"idle", repo:d.repos[0], timer:ri(1,3), alive:true,
    bootAt:Date.now()-ri(200000,4000000), lastEndTxt:"—", lastKey:"—",
    sessions:[], queue:[], flash:0
  };
  return b;
});
var byId={}; boxes.forEach(function(b){ byId[b.id]=b; });

// triage whiteboard standing slots (art px)
var officeCx=(OFFICE.c0+OFFICE.c1+1)/2;
var triSlots=[];
for(var s=0;s<5;s++){ triSlots.push({x:(OFFICE.c0+3+s*3)*TILE, y:(OFFICE.r1-1)*TILE}); }
function freeTriSlot(){
  var used={}; boxes.forEach(function(b){ if(b.triSlot!=null) used[b.triSlot]=1; });
  for(var i=0;i<triSlots.length;i++) if(!used[i]) return i;
  return 0;
}

/* ---------- particles & effects ---------- */
var sparks=[];
function spawnSpark(x,y,col){
  sparks.push({x:x,y:y,vx:rnd(-0.4,0.4),vy:rnd(-1.1,-0.4),life:rnd(0.4,0.9),col:col});
}
function stepSparks(dt){
  for(var i=sparks.length-1;i>=0;i--){
    var p=sparks[i]; p.x+=p.vx; p.y+=p.vy; p.vy+=0.05; p.life-=dt;
    if(p.life<=0) sparks.splice(i,1);
  }
}

/* ---------- offscreen art buffer ---------- */
var buf=document.createElement("canvas"); buf.width=W; buf.height=H;
var p=buf.getContext("2d"); p.imageSmoothingEnabled=false;
function R(x,y,w,h,col){ p.fillStyle=col; p.fillRect(x|0,y|0,w|0,h|0); }

/* ---------- floor + zones ---------- */
function drawFloor(){
  R(0,0,W,H,"#0b111c");
  // subtle tech grid
  p.fillStyle="#0f1828";
  for(var gx=0;gx<COLS;gx+=1){ if(gx%2===0) R(gx*TILE,0,1,H,"#0d1524"); }
  for(var gy=0;gy<ROWS;gy+=1){ if(gy%2===0) R(0,gy*TILE,W,1,"#0d1524"); }

  // office first (whiteboard room)
  drawRoom(OFFICE, "#182338", "#243654", null);
  drawWhiteboard();

  boxes.forEach(function(b){
    var z=b.zone;
    var tint = shade(b.color,0.28);
    drawRoom({c0:z.c0,r0:z.r0,c1:z.c1,r1:z.r1}, "#101a2b", shade(b.color,0.6), tint);
    drawRacks(b);
  });
}
function drawRoom(z,fill,wall,accent){
  var x=z.c0*TILE, y=z.r0*TILE, w=(z.c1-z.c0+1)*TILE, h=(z.r1-z.r0+1)*TILE;
  R(x,y,w,h,fill);
  // floor checker
  for(var cc=z.c0;cc<=z.c1;cc++) for(var rr=z.r0;rr<=z.r1;rr++){
    if((cc+rr)%2===0) R(cc*TILE,rr*TILE,TILE,TILE,shade(fill,1.08));
  }
  if(accent){ R(x,y,w,2,accent); } // top accent stripe
  // walls (frame)
  R(x,y,w,1,wall); R(x,y+h-1,w,1,wall); R(x,y,1,h,wall); R(x+w-1,y,1,h,wall);
}

/* server racks along a zone's north wall — one per repo */
function drawRacks(b){
  var z=b.zone, n=b.repos.length;
  var startC=z.c0+2, gap=3;
  for(var i=0;i<n;i++){
    var rc=startC+i*gap, rx=rc*TILE, ry=(z.r0+2)*TILE;
    var active=(b.repos[i]===b.repo) && (b.state==="building"||b.state==="reviewing");
    drawRack(rx,ry,active?STATE[b.state].c:null,b.phase+i);
  }
}
function drawRack(x,y,glow,ph){
  var w=14,h=20;
  R(x,y,w,h,"#0c1420");            // cabinet
  R(x,y,w,1,"#2a3a55"); R(x,y,1,h,"#1c2942"); R(x+w-1,y,1,h,"#0a101b"); R(x,y+h-1,w,1,"#0a101b");
  // rack units with blinking LEDs
  for(var u=0;u<5;u++){
    var uy=y+2+u*3.4;
    R(x+2,uy,w-4,2,"#141f31");
    var on = ((Math.floor(ph*3)+u)%3)===0;
    var led = glow ? glow : (on?"#3a5a48":"#243248");
    R(x+w-4,uy,1,1,led);
    R(x+3,uy,1,1, on?"#2f4a66":"#1a2740");
  }
  if(glow){
    // active glow halo
    p.globalAlpha=0.18; R(x-1,y-1,w+2,h+2,glow); p.globalAlpha=1;
  }
}

/* ---------- whiteboard (triage office) ---------- */
var boardCols=["needs-triage","claimed","blocked","ready"];
var boardColColor={ "needs-triage":"#f5b743","claimed":"#57b0ff","blocked":"#ff5c5c","ready":"#63c896" };
var stickies=[];
(function seedStickies(){
  for(var i=0;i<7;i++) stickies.push({col:pick(boardColColor?boardCols:[]),row:ri(0,3)});
})();
function drawWhiteboard(){
  var x=(OFFICE.c0+2)*TILE, y=(OFFICE.r0+2)*TILE, w=(OFFICE.c1-OFFICE.c0-3)*TILE, h=5*TILE;
  R(x-1,y-1,w+2,h+2,"#0a1220");
  R(x,y,w,h,"#e7ecf3");           // board
  R(x,y,w,1,"#ffffff"); R(x,y+h-1,w,1,"#aeb8c8");
  // column dividers + header ticks
  var cw=w/4;
  for(var c=0;c<4;c++){
    var cx=x+c*cw;
    if(c>0) R(cx,y,1,h,"#c3ccd8");
    R(cx+2,y+2,cw-6,1,boardColColor[boardCols[c]]);
  }
  // sticky notes
  stickies.forEach(function(s,i){
    var ci=boardCols.indexOf(s.col); if(ci<0) ci=0;
    var sx=x+ci*cw+3+ (i%2)*4, sy=y+5+s.row*4;
    R(sx,sy,4,3,boardColColor[s.col]);
    R(sx,sy,4,1,shade(boardColColor[s.col],1.3));
  });
}

/* ---------- robot sprite ---------- */
function drawRobot(ctxScaleX, b){
  var x=Math.round(b.x), y=Math.round(b.y); // feet center
  var walking = Math.abs(b.x-b.tx)>0.6 || Math.abs(b.y-b.ty)>0.6;
  var bob = (walking && !reduced) ? Math.round(Math.sin(b.phase*10)) : 0;
  var st = STATE[b.state];
  var body = b.alive ? b.color : "#4a5364";
  var bodyD = shade(body,0.62), head = shade(body,1.18);
  var light = b.alive ? st.c : "#ff5c5c";
  var vis = "#0c1119";

  if(!b.alive){ drawDead(x,y); return; }

  y += bob;
  // shadow
  p.globalAlpha=0.28; R(x-5,y+1,10,2,"#05080e"); p.globalAlpha=1;
  // legs (alternate when walking)
  var lp = walking && !reduced ? (Math.sin(b.phase*10)>0?1:-1) : 0;
  R(x-3,y-3+ (lp>0?0:0),2,3,bodyD);
  R(x+1,y-3,2,3,bodyD);
  R(x-3,y-1,2,1, lp>0?shade(body,0.5):bodyD);
  R(x+1,y-1,2,1, lp<0?shade(body,0.5):bodyD);
  // body
  R(x-4,y-9,8,6,body);
  R(x-4,y-9,8,1,head);
  R(x-4,y-9,1,6,shade(body,0.8)); R(x+3,y-9,1,6,bodyD);
  // chest light (state)
  R(x-1,y-7,2,2,light);
  // arms
  var swing = (b.state==="building" && !reduced) ? Math.round(Math.sin(b.phase*12)*2) : 0;
  R(x-6,y-8,2,4,bodyD);                 // left arm
  R(x+4,y-8+swing,2,4,bodyD);           // right arm (works)
  // head
  R(x-3,y-14,6,5,head);
  R(x-3,y-14,6,1,shade(body,1.35));
  R(x-2,y-12,4,2,vis);                  // visor
  // eyes
  R(x-2,y-12,1,1,light); R(x+1,y-12,1,1,light);
  // antenna (blinks with state)
  R(x,y-16,1,2,shade(body,0.7));
  var blink = reduced ? 1 : (Math.sin(b.phase*6)>-0.3?1:0.3);
  p.globalAlpha=blink; R(x-1,y-17,2,2,light); p.globalAlpha=1;

  // tool by state
  var handX=x+6, handY=y-6+swing;
  if(b.state==="building"){
    R(handX,handY-2,1,4,"#9fb0c6"); R(handX-1,handY-3,3,2,"#c7d3e2"); // hammer
  } else if(b.state==="reviewing"){
    R(handX,handY-1,3,3,"#0c1119"); R(handX,handY-1,3,1,light); R(handX,handY+1,3,1,light);
    R(handX,handY-1,1,3,light); R(handX+2,handY-1,1,3,light); R(handX+3,handY+2,2,2,"#9fb0c6"); // magnifier
  } else if(b.state==="triaging"){
    R(handX,handY-2,4,5,"#e7ecf3"); R(handX+1,handY-1,2,1,"#8a96a8"); R(handX+1,handY+1,2,1,"#8a96a8"); // clipboard
  }

  if(b.flash>0){ // prompt pickup ping
    p.globalAlpha=b.flash*0.9; R(x-2,y-22,4,3,"#7fd7ff"); p.globalAlpha=1;
  }
}
function drawDead(x,y){
  // toppled robot, greyed, X eyes
  p.globalAlpha=0.3; R(x-6,y-1,13,2,"#05080e"); p.globalAlpha=1;
  R(x-6,y-6,12,5,"#3a4252");     // body on its side
  R(x-6,y-6,12,1,"#4b5568");
  R(x+4,y-8,5,6,"#454d5e");      // head fallen
  // X eyes
  R(x+5,y-7,1,1,"#ff5c5c"); R(x+7,y-7,1,1,"#ff5c5c"); R(x+6,y-6,1,1,"#ff5c5c");
  R(x+5,y-5,1,1,"#ff5c5c"); R(x+7,y-5,1,1,"#ff5c5c");
  // alert
  if(!reduced && Math.sin(Date.now()/220)>0){ R(x-1,y-12,2,4,"#ff5c5c"); R(x-1,y-7,2,1,"#ff5c5c"); }
}

/* ---------- sparks render ---------- */
function drawSparks(){
  sparks.forEach(function(s){
    p.globalAlpha=clamp(s.life,0,1); R(Math.round(s.x),Math.round(s.y),1,1,s.col);
  });
  p.globalAlpha=1;
}

/* ============================================================
   Simulation tick (mock telemetry)
   ============================================================ */
var TICK_MS=2600, tickCount=0;
function outcomeFor(kind){
  if(kind==="build")  return pick(["opened PR","pushed fixups","needs-human","resumed"]);
  if(kind==="review") return pick(["approved","changes-requested","commented","re-request → approved"]);
  if(kind==="triage") return pick(["labeled ready","routed to builder","marked blocked","ruling posted"]);
  return "ok";
}
function startSession(b,forceKind){
  var kind = forceKind || STATE[b.state].kind;
  b.repo = pick(b.repos);
  b.lastKey = (kind==="triage") ? "board" : issueKey(b.repo);
  logLine(b,"k-"+(kind==="build"?"build":kind==="review"?"review":"triage"),
    "SESSION START kind="+kind+" key="+b.lastKey+" timeout="+(kind==="build"?1200:600)+"s");
  b.sessions.unshift({t:nowClock(),txt:"START "+kind+" "+b.lastKey,cls:""});
  b.sessions=b.sessions.slice(0,6);
}
function endSession(b){
  var kind=STATE[b.state].kind; if(kind==="idle"||kind==="dead") return;
  var rc = chance(0.12)?1:0, dur=ri(18,140), out=rc?"aborted (budget)":outcomeFor(kind);
  b.lastEndTxt="rc="+rc+" · "+out;
  logLine(b,"k-"+(kind==="build"?"build":kind==="review"?"review":"triage"),
    "SESSION END kind="+kind+" rc="+rc+" dur="+dur+"s outcome="+out,rc?"cr":"ok");
  b.sessions.unshift({t:nowClock(),txt:"END "+kind+" "+out,cls:rc?"warn":"ok"});
  b.sessions=b.sessions.slice(0,6);
}
function setState(b,st){
  if(b.state===st) return;
  // leaving a working state → close it
  if(b.state==="building"||b.state==="reviewing"||b.state==="triaging") endSession(b);
  if(b.triSlot!=null && st!=="triaging"){ b.triSlot=null; }
  b.state=st;
  if(st==="triaging"){
    b.triSlot=freeTriSlot(); var sl=triSlots[b.triSlot]; b.tx=sl.x; b.ty=sl.y; startSession(b);
  } else if(st==="building"||st==="reviewing"){
    b.tx=b.home.x; b.ty=b.home.y; startSession(b);
  } else if(st==="idle"){
    wander(b);
  }
}
function wander(b){
  var z=b.zone;
  b.tx=(ri(z.c0+2,z.c1-2)+0.5)*TILE;
  b.ty=(ri(z.r0+4,z.r1-1)+0.5)*TILE;
}
function tick(){
  tickCount++;
  boxes.forEach(function(b){
    // disconnected boxes: quiet, maybe operator revives them
    if(!b.alive){
      if(chance(0.22)){
        b.alive=true; b.bootAt=Date.now(); b.state="idle"; wander(b);
        logLine(b,"k-boot","boot: gh ✓ box ✓ — on duty");
      } else {
        if(tickCount%2===0) logLine(b,"k-dead","⚠ no evidence line — cron silent");
      }
      return;
    }
    // pick up an operator message on the next tick
    if(b.queue.length){
      var q=b.queue.shift(); q.picked=true; q.pickedAt=nowClock(); b.flash=1;
      b.picked=b.picked||[]; b.picked.push(q);
      logLine(b,"k-prompt","📨 operator prompt picked up → kind="+(b.role==="triage"?"triage":b.role==="builder"?"build":"review"));
      setState(b, b.role==="triage"?"triaging":b.role==="builder"?"building":"reviewing");
      b.timer=ri(2,4);
      if(inspFor===b.id) renderQueue(b);
      return;
    }
    // rare disconnect
    if(chance(0.02)){
      endSession(b); b.alive=false; b.state="dead";
      logLine(b,"k-dead","⚠ tick boundary missed — box unreachable");
      if(inspFor===b.id) refreshInspector();
      return;
    }
    b.timer--;
    if(b.timer>0){
      if(b.state==="idle" && chance(0.5)) wander(b);
      return;
    }
    // choose next activity by role
    var r=Math.random(), next;
    if(b.role==="triage")      next = r<0.62?"triaging":"idle";
    else if(b.role==="builder")next = r<0.5?"building": r<0.68?"triaging":"idle";
    else                       next = r<0.5?"reviewing":r<0.68?"triaging":"idle";
    setState(b,next);
    b.timer = next==="idle"?ri(1,3):ri(2,5);
  });
  updateRoster();
  if(inspOpen) refreshInspector();
}

/* ============================================================
   Movement + main render loop
   ============================================================ */
var lastT=0;
function frame(t){
  var dt=Math.min(0.05,(t-lastT)/1000)||0.016; lastT=t;
  // step agents
  boxes.forEach(function(b){
    b.phase += dt;
    if(b.flash>0) b.flash=Math.max(0,b.flash-dt*1.6);
    if(!b.alive) return;
    var dx=b.tx-b.x, dy=b.ty-b.y, d=Math.hypot(dx,dy);
    if(d>0.6){
      var sp=(reduced?60:28)*dt;
      var m=Math.min(sp,d); b.x+=dx/d*m; b.y+=dy/d*m;
      b.face=dx<0?-1:1;
    } else { b.x=b.tx; b.y=b.ty; }
    // working effects
    if(!reduced){
      if(b.state==="building" && chance(0.5)) spawnSpark(b.x+6, b.y-6, "#ffcf5a");
      if(b.state==="reviewing" && chance(0.12)) spawnSpark(b.x+7, b.y-6, "#8ec6ff");
    }
  });
  stepSparks(dt);

  // draw world
  drawFloor();
  // scan lines for reviewers on their active rack
  boxes.forEach(function(b){ if(b.alive && b.state==="reviewing") drawScan(b); });
  drawSparks();
  // draw robots sorted by y for depth
  boxes.slice().sort(function(a,c){return a.y-c.y;}).forEach(function(b){ drawRobot(1,b); });
  // hover ring
  if(hoverId){ var hb=byId[hoverId]; if(hb){ p.globalAlpha=0.9; ringAt(hb.x,hb.y-8,STATE[hb.state].c); p.globalAlpha=1; } }

  blit();
  requestAnimationFrame(frame);
}
function ringAt(x,y,col){
  p.strokeStyle=col; // pixel ring
  R(x-8,y-9,16,1,col); R(x-8,y+8,16,1,col); R(x-9,y-8,1,16,col); R(x+8,y-8,1,16,col);
}
function drawScan(b){
  // find active rack x for current repo
  var z=b.zone, i=b.repos.indexOf(b.repo); if(i<0)i=0;
  var rx=(z.c0+2+i*3)*TILE, ry=(z.r0+2)*TILE;
  var yy=ry + ((Math.sin(b.phase*2)+1)/2)*18;
  p.globalAlpha=0.5; R(rx,Math.round(yy),14,1,"#8ec6ff"); p.globalAlpha=1;
}

/* ---------- blit offscreen → screen ---------- */
var view=document.getElementById("view"), vctx=view.getContext("2d");
var vw=0,vh=0,scale=1,ox=0,oy=0,dpr=1;
function resize(){
  var host=document.getElementById("floor"); var r=host.getBoundingClientRect();
  dpr=window.devicePixelRatio||1;
  vw=r.width; vh=r.height;
  view.width=Math.floor(vw*dpr); view.height=Math.floor(vh*dpr);
  scale=Math.max(1,Math.min((vw)/W,(vh)/H));   // fit whole floor
  ox=Math.round((vw-W*scale)/2); oy=Math.round((vh-H*scale)/2);
  vctx.setTransform(dpr,0,0,dpr,0,0); vctx.imageSmoothingEnabled=false;
  layoutLabels();
}
function blit(){
  vctx.clearRect(0,0,vw,vh);
  vctx.fillStyle="#0b111c"; vctx.fillRect(0,0,vw,vh);
  vctx.imageSmoothingEnabled=false;
  vctx.drawImage(buf,0,0,W,H, ox,oy, W*scale, H*scale);
}
function artToScreen(ax,ay){ return {x:ox+ax*scale, y:oy+ay*scale}; }
function screenToArt(sx,sy){ return {x:(sx-ox)/scale, y:(sy-oy)/scale}; }

/* ---------- DOM zone labels ---------- */
var labelEls={};
function buildLabels(){
  var floor=document.getElementById("floor");
  // office label
  makeLabel("__office", "<b>Office</b> <span class='rl'>· triage board</span>");
  boxes.forEach(function(b){
    makeLabel(b.id, "<b>"+b.id+"</b> <span class='rl'>· "+b.role+"</span>");
  });
  function makeLabel(id,html){
    var el=document.createElement("div"); el.className="zlabel"; el.innerHTML=html;
    floor.appendChild(el); labelEls[id]=el;
  }
}
function layoutLabels(){
  if(!labelEls.__office) return;
  var op=artToScreen(OFFICE.c0*TILE+3, OFFICE.r0*TILE+3);
  place(labelEls.__office, op.x, op.y);
  boxes.forEach(function(b){
    var pt=artToScreen(b.zone.c0*TILE+3, (b.zone.r1)*TILE-11);
    place(labelEls[b.id], pt.x, pt.y);
  });
  function place(el,x,y){ el.style.left=x+"px"; el.style.top=y+"px"; }
}

/* ============================================================
   HUD: roster, ticker, tooltip, inspector
   ============================================================ */
var rosterEl=document.getElementById("roster");
function buildRoster(){
  boxes.forEach(function(b){
    var row=document.createElement("div"); row.className="rrow"; row.dataset.id=b.id;
    row.innerHTML=
      "<span class='av' style='background:"+b.color+"'></span>"+
      "<span class='who'><span class='nm'>"+b.id+"</span><span class='role'>"+b.agent+" · "+b.role+"</span></span>"+
      "<span class='chip'></span>";
    row.addEventListener("click",function(){ focusBox(b.id); });
    rosterEl.appendChild(row);
  });
  updateRoster();
}
function updateRoster(){
  boxes.forEach(function(b){
    var row=rosterEl.querySelector("[data-id='"+b.id+"']"); if(!row) return;
    var chip=row.querySelector(".chip"); var st=STATE[b.state];
    chip.textContent=st.label;
    chip.style.color=st.c; chip.style.background=shade(st.c,0.16);
    chip.style.borderColor=shade(st.c,0.4);
    row.classList.toggle("sel", inspFor===b.id);
  });
}

/* ticker */
var logEl=document.getElementById("log"), logCount=0;
function logLine(b,cls,msg,extra){
  var l=document.createElement("div"); l.className="l "+cls;
  var m=msg;
  if(extra==="ok") m=msg.replace(/outcome=([^\s]+.*)$/,"outcome=<span class='ok'>$1</span>");
  if(extra==="cr") m=msg.replace(/rc=1/,"<span class='cr'>rc=1</span>");
  l.innerHTML="<span class='t'>"+nowClock()+"</span><span class='b'>"+b.id+"</span><span class='m'>"+m+"</span>";
  logEl.appendChild(l); logCount++;
  while(logEl.childNodes.length>80) logEl.removeChild(logEl.firstChild);
  logEl.scrollTop=logEl.scrollHeight;
}

/* tooltip */
var tip=document.getElementById("tip");
function showTip(b,sx,sy){
  tip.querySelector(".t1").textContent=b.id;
  tip.querySelector(".t2").textContent = b.alive ? (STATE[b.state].label+" · "+b.repo) : "Disconnected · cron silent";
  tip.style.left=sx+"px"; tip.style.top=sy+"px"; tip.style.opacity="1";
}
function hideTip(){ tip.style.opacity="0"; }

/* ---------- inspector ---------- */
var inspEl=document.getElementById("inspector"), inspOpen=false, inspFor=null;
function openInspector(id){
  inspFor=id; inspOpen=true; inspEl.classList.add("open");
  refreshInspector(); updateRoster();
}
function closeInspector(){ inspOpen=false; inspFor=null; inspEl.classList.remove("open"); updateRoster(); }
function fmtUptime(ms){
  if(ms<0) ms=0; var s=Math.floor(ms/1000);
  var h=Math.floor(s/3600), m=Math.floor((s%3600)/60), ss=s%60;
  return (h?h+"h ":"")+pad(m)+"m "+pad(ss)+"s";
}
function refreshInspector(){
  var b=byId[inspFor]; if(!b) return;
  document.getElementById("insp-id").textContent=b.id;
  document.getElementById("insp-meta").textContent=b.agent+" · "+b.role;
  document.getElementById("insp-badge").style.background=shade(b.color,0.22);
  drawAvatar(b);
  var st=STATE[b.state];
  var vs=document.getElementById("v-status"); vs.textContent=st.label; vs.style.color=st.c;
  document.getElementById("v-uptime").textContent=b.alive?fmtUptime(Date.now()-b.bootAt):"—";
  document.getElementById("v-repo").textContent=b.alive?b.repo:"—";
  document.getElementById("v-tick").textContent=b.alive?"≤5m ago":"silent";
  var tl=document.getElementById("v-timeline"); tl.innerHTML="";
  if(!b.sessions.length){ tl.innerHTML="<div class='ln'><span class='tk'>—</span>no sessions yet</div>"; }
  b.sessions.forEach(function(s){
    var ln=document.createElement("div"); ln.className="ln";
    ln.innerHTML="<span class='tk'>"+s.t+"</span><span class='"+(s.cls||"")+"'>"+s.txt+"</span>";
    tl.appendChild(ln);
  });
  renderQueue(b);
}
function renderQueue(b){
  var q=document.getElementById("queue"); q.innerHTML="";
  b.queue.forEach(function(item){
    q.appendChild(qEl(item,false));
  });
  // show recently picked (kept briefly on the item)
  (b.picked||[]).slice(-2).forEach(function(item){ q.appendChild(qEl(item,true)); });
}
function qEl(item,picked){
  var d=document.createElement("div"); d.className="qitem"+(picked?" picked":"");
  d.innerHTML="<div class='qs'>"+(picked?"picked up "+item.pickedAt:"queued "+item.at+" · waiting for next tick")+"</div>"+escapeHtml(item.text);
  return d;
}
function escapeHtml(s){ return s.replace(/[&<>]/g,function(c){return c==="&"?"&amp;":c==="<"?"&lt;":"&gt;";}); }

/* inspector avatar (static robot) */
var avEl=document.getElementById("insp-av"), avc=avEl.getContext("2d");
function drawAvatar(b){
  avc.imageSmoothingEnabled=false; avc.clearRect(0,0,34,34);
  // reuse main buffer draw by temporarily targeting: simpler to redraw a mini robot
  var save={x:b.x,y:b.y,tx:b.tx,ty:b.ty,phase:b.phase};
  // draw into a tiny offscreen then scale
  var mini=document.createElement("canvas"); mini.width=17; mini.height=17;
  var mp=mini.getContext("2d");
  var oldp=p; // swap R target
  drawMiniRobot(mp,b);
  avc.imageSmoothingEnabled=false; avc.drawImage(mini,0,0,17,17,0,0,34,34);
}
function drawMiniRobot(ctx,b){
  function r(x,y,w,h,c){ ctx.fillStyle=c; ctx.fillRect(x,y,w,h); }
  var x=8,y=15, body=b.alive?b.color:"#4a5364", light=b.alive?STATE[b.state].c:"#ff5c5c";
  r(x-3,y-3,2,3,shade(body,0.62)); r(x+1,y-3,2,3,shade(body,0.62));
  r(x-4,y-9,8,6,body); r(x-1,y-7,2,2,light);
  r(x-6,y-8,2,4,shade(body,0.62)); r(x+4,y-8,2,4,shade(body,0.62));
  r(x-3,y-14,6,5,shade(body,1.18)); r(x-2,y-12,4,2,"#0c1119");
  r(x-2,y-12,1,1,light); r(x+1,y-12,1,1,light);
  r(x,y-16,1,2,shade(body,0.7)); r(x-1,y-17,2,2,light);
}

/* ---------- interaction ---------- */
function hitRobot(ax,ay){
  var best=null,bd=1e9;
  boxes.forEach(function(b){
    var dx=ax-b.x, dy=ay-(b.y-8), d=dx*dx+dy*dy;
    if(d<bd && Math.abs(dx)<9 && dy>-14 && dy<10){ bd=d; best=b; }
  });
  return best;
}
view.addEventListener("mousemove",function(e){
  var r=view.getBoundingClientRect(); var a=screenToArt(e.clientX-r.left,e.clientY-r.top);
  var b=hitRobot(a.x,a.y);
  if(b){ hoverId=b.id; view.style.cursor="pointer";
    var pt=artToScreen(b.x,b.y-16); showTip(b, pt.x, pt.y);
  } else { hoverId=null; hideTip(); }
});
view.addEventListener("mouseleave",function(){ hoverId=null; hideTip(); });
view.addEventListener("dblclick",function(e){
  var r=view.getBoundingClientRect(); var a=screenToArt(e.clientX-r.left,e.clientY-r.top);
  var b=hitRobot(a.x,a.y); if(b) openInspector(b.id);
});
var hoverId=null;
function focusBox(id){
  var b=byId[id]; if(!b) return;
  openInspector(id);
  b.flash=1; // little ping
}

document.getElementById("insp-close").addEventListener("click",closeInspector);
document.getElementById("prompt-send").addEventListener("click",sendPrompt);
document.getElementById("prompt-in").addEventListener("keydown",function(e){
  if((e.metaKey||e.ctrlKey)&&e.key==="Enter") sendPrompt();
});
function sendPrompt(){
  var b=byId[inspFor]; if(!b) return;
  var ta=document.getElementById("prompt-in"); var txt=ta.value.trim(); if(!txt) return;
  if(!b.alive){ // can't reach a dead box
    var q=document.getElementById("queue");
    var w=document.createElement("div"); w.className="qitem"; w.style.borderLeftColor="var(--dead)";
    w.innerHTML="<div class='qs' style='color:var(--dead)'>undeliverable</div>Box is disconnected — no tick to drain the channel. Message not queued.";
    q.prepend(w); return;
  }
  b.picked=b.picked||[];
  var item={text:txt, at:nowClock(), picked:false};
  b.queue.push(item);
  // when it gets picked up in tick(), move to picked list
  var origShift=b.queue; // handled in tick; also mirror to picked there
  ta.value="";
  renderQueue(b);
  // mirror pick into picked[] when tick consumes it
}
// hook: when tick consumes a queue item we also want it visible as "picked".
// Patch tick's consumption by wrapping: we recorded pick in tick via q.picked; also push to b.picked.
(function patchPick(){
  // wrap logLine-free: we already set q.picked & pickedAt in tick(); ensure it lands in b.picked
})();

/* about modal */
var aboutBg=document.getElementById("about-bg");
document.getElementById("about-btn").addEventListener("click",function(){ aboutBg.classList.add("open"); });
document.getElementById("about-close").addEventListener("click",function(){ aboutBg.classList.remove("open"); });
aboutBg.addEventListener("click",function(e){ if(e.target===aboutBg) aboutBg.classList.remove("open"); });
document.addEventListener("keydown",function(e){ if(e.key==="Escape"){ aboutBg.classList.remove("open"); if(inspOpen) closeInspector(); } });

/* clock */
function tickClock(){ document.getElementById("clock").textContent=nowClock(); }

/* ---------- boot ---------- */
function init(){
  buildLabels(); buildRoster();
  window.addEventListener("resize",resize); resize();
  // seed a few log lines / states
  boxes.forEach(function(b,i){
    if(i%3===0) { b.state = b.role==="builder"?"building":b.role==="reviewer"?"reviewing":"triaging"; b.tx=b.state==="triaging"?triSlots[(b.triSlot=freeTriSlot(),b.triSlot)].x:b.home.x; b.ty=b.state==="triaging"?triSlots[b.triSlot].y:b.home.y; startSession(b); }
  });
  updateRoster();
  tickClock(); setInterval(tickClock,1000);
  setInterval(tick, TICK_MS);
  requestAnimationFrame(frame);
}
init();
})();
