"use strict";
(function(){
/* ============================================================
   Fleet Floor — detailed pixel god-view of heavy-duty/crew
   Dense interiors baked once to a static background; robots,
   effects and a full-res lighting pass drawn live on top.
   Every box has ALL repos. Bots stay in their quarters and
   CALL in for triage (no cross-room walking).
   ============================================================ */

var TILE=16, reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
/* 3x3 room grid */
var GX=[1,19,37], GY=[1,14,27], RW=16, RH=11;
var COLS=54, ROWS=39, W=COLS*TILE, H=ROWS*TILE;   // 864 x 624

var VENDOR={ claude:"#f6a04d", codex:"#37d4a6", grok:"#b07cff", kimi:"#ff72b6" };
var REPOS=["ceremony","cast","box","rig","incubator","crew"];
var REPOCOL={ ceremony:"#e0913d", cast:"#3fb0e6", box:"#7bc86a", rig:"#e0664a", incubator:"#a884ff", crew:"#e6c34a" };
var STATE={
  building:{c:"#f7bd4e",label:"Building",kind:"build"},
  reviewing:{c:"#5cb4ff",label:"Reviewing",kind:"review"},
  triaging:{c:"#c98bff",label:"Calling triage",kind:"triage"},
  idle:{c:"#5fce9b",label:"Idle",kind:"idle"},
  dead:{c:"#ff5c5c",label:"Disconnected",kind:"dead"}
};
var PROFILE={
  claude:{head:"round", ears:0, antenna:"ball", eyes:"two",    trim:"#ffd9a6"},
  codex: {head:"square",ears:0, antenna:"rod",  eyes:"visor",  trim:"#9df4de"},
  grok:  {head:"round", ears:0, antenna:"rod",  eyes:"cyclops",trim:"#dcc6ff", tall:3},
  kimi:  {head:"round", ears:2, antenna:"none", eyes:"two",    trim:"#ffc6e2"}
};

/* rooms: [ci,ri, type, id, agent, role] */
var ROOMDEFS=[
  {g:[0,0], type:"triage",   id:"claude-triage",  agent:"claude", role:"triage"},
  {g:[1,0], type:"box",      id:"claude-builder", agent:"claude", role:"builder"},
  {g:[2,0], type:"box",      id:"claude-reviewer",agent:"claude", role:"reviewer"},
  {g:[0,1], type:"operator", id:"__operator"},
  {g:[1,1], type:"lounge",   id:"__lounge"},
  {g:[2,1], type:"box",      id:"codex-builder",  agent:"codex",  role:"builder"},
  {g:[0,2], type:"box",      id:"kimi-reviewer",  agent:"kimi",   role:"reviewer"},
  {g:[1,2], type:"box",      id:"grok-reviewer",  agent:"grok",   role:"reviewer"},
  {g:[2,2], type:"box",      id:"codex-reviewer", agent:"codex",  role:"reviewer"}
];

/* ---------- utils ---------- */
function rnd(a,b){return a+Math.random()*(b-a);}
function ri(a,b){return Math.floor(rnd(a,b+1));}
function pick(a){return a[ri(0,a.length-1)];}
function chance(p){return Math.random()<p;}
function clamp(v,a,b){return v<a?a:(v>b?b:v);}
function hex(h){h=h.replace("#","");return [parseInt(h.substr(0,2),16),parseInt(h.substr(2,2),16),parseInt(h.substr(4,2),16)];}
function shade(h,f){var c=parseRGB(h),r,gg,b;if(f<=1){r=c[0]*f;gg=c[1]*f;b=c[2]*f;}else{var t=f-1;r=c[0]+(255-c[0])*t;gg=c[1]+(255-c[1])*t;b=c[2]+(255-c[2])*t;}return "rgb("+Math.round(clamp(r,0,255))+","+Math.round(clamp(gg,0,255))+","+Math.round(clamp(b,0,255))+")";}
function parseRGB(s){if(s[0]==="#")return hex(s);var m=s.match(/(\d+),\s*(\d+),\s*(\d+)/);return [+m[1],+m[2],+m[3]];}
function rgba(h,a){var c=parseRGB(h);return "rgba("+c[0]+","+c[1]+","+c[2]+","+a+")";}
function mix(a,b,t){var ca=parseRGB(a),cb=parseRGB(b);return "rgb("+Math.round(ca[0]+(cb[0]-ca[0])*t)+","+Math.round(ca[1]+(cb[1]-ca[1])*t)+","+Math.round(ca[2]+(cb[2]-ca[2])*t)+")";}
function pad(n){return (n<10?"0":"")+n;}
function nowClock(){var d=new Date();return pad(d.getUTCHours())+":"+pad(d.getUTCMinutes())+":"+pad(d.getUTCSeconds());}
function issueKey(repo){return repo+"#"+ri(11,148);}

/* ---------- drawing primitives (target = global g) ---------- */
var g;
function R(x,y,w,h,c){g.fillStyle=c;g.fillRect(x|0,y|0,w|0,h|0);}
var OL="#0a0e18";
/* outlined, beveled block — the furniture workhorse */
function block(x,y,w,h,base,hi,lo){
  R(x,y,w,h,OL);
  R(x+1,y+1,w-2,h-2,base);
  R(x+1,y+1,w-2,1,hi); R(x+1,y+1,1,h-2,hi);
  R(x+1,y+h-2,w-2,1,lo); R(x+w-2,y+1,1,h-2,lo);
}
function outline(x,y,w,h){R(x-1,y,w+2,h,OL);R(x,y-1,w,h+2,OL);}

/* ============================================================
   FURNITURE / PROP LIBRARY  (drawn into the static background)
   ============================================================ */
function repoRack(x,y,repo,active){
  var w=22,h=44, rc=REPOCOL[repo];
  block(x,y,w,h,"#171f30","#2a3852","#0c1220");
  // repo colour plate (label)
  R(x+2,y+2,w-4,4,shade(rc,0.5)); R(x+2,y+2,w-4,1,rc); R(x+3,y+3,w-6,1,shade(rc,1.2));
  // rack units with LEDs + drive slots
  for(var u=0;u<6;u++){
    var uy=y+8+u*5;
    R(x+2,uy,w-4,4,"#0e1626"); R(x+2,uy,w-4,1,"#1b2740");
    R(x+3,uy+1,10,2,"#12203a");                       // drive face
    var on=(u+ (x%3))%2===0;
    R(x+w-5,uy+1,2,2, on?shade(rc,1.1):"#22344e");     // status led
    R(x+w-8,uy+1,1,2, on?"#2f4a66":"#1a2740");
  }
  // little vent grille at bottom
  R(x+3,y+h-5,w-6,1,"#0c1220"); R(x+3,y+h-3,w-6,1,"#0c1220");
  return {x:x+w/2, y:y+h-2, repo:repo};
}
function serverTower(x,y){
  block(x,y,14,26,"#1a2233","#2c3a54","#0c1220");
  for(var i=0;i<4;i++){R(x+3,y+3+i*5,8,3,"#101a2c");R(x+9,y+4+i*5,1,1,"#3aa06a");}
  R(x+3,y+22,8,1,"#0c1220");
}
function cableTray(x,y,w,accent){
  R(x,y,w,3,"#0c1424"); R(x,y,w,1,"#1a2740");
  for(var i=0;i<w;i+=6){R(x+i,y+1,3,1,rgba(accent,0.35));}
}
function workstation(x,y,vendor){
  // desk
  block(x,y+16,46,8,"#5a3f26","#7a5636","#3a2716");
  R(x+2,y+18,42,1,"#6e4c2e");                        // wood grain
  R(x+3,y+22,2,4,"#2a1c10"); R(x+41,y+22,2,4,"#2a1c10"); // legs
  // dual monitors
  drawMonitor(x+3,y+2, vendor);
  drawMonitor(x+25,y+2, vendor);
  // keyboard + mouse
  block(x+12,y+17,18,3,"#20283a","#2e3850","#141c2c");
  for(var k=0;k<8;k++)R(x+13+k*2,y+18,1,1,"#3a465e");
  R(x+33,y+18,3,2,"#20283a");
  // mug
  block(x+38,y+13,4,4,"#8a4436","#b45a44","#5a2c22"); R(x+37,y+14,1,2,"#8a4436");
  // papers
  R(x+7,y+15,5,2,"#d7deea");
}
function drawMonitor(x,y,vendor){
  block(x,y,18,13,"#0c1220","#22304a","#060a12");
  R(x+2,y+2,14,8,"#0f2036");
  // faint code lines (static; live glow added dynamically)
  var cl=["#1d3a54","#25506e","#1d3a54","#2a5a78"];
  for(var i=0;i<4;i++){R(x+3,y+3+i*2,ri(6,12),1,cl[i%4]);}
  R(x+8,y+13,2,2,"#0c1220"); R(x+5,y+15,8,1,"#141c2c");     // stand
}
function shelf(x,y){
  block(x,y,26,40,"#4a3320","#664628","#2c1e10");
  var spines=["#c0503a","#3f7fb0","#c9a33a","#4f9e5a","#8a5fb0","#c96a3a","#3f9e8a"];
  for(var s=0;s<3;s++){
    var sy=y+3+s*12; R(x+2,sy+10,22,2,"#2c1e10");        // shelf board
    if(s<2){ var bx=x+3; for(var b=0;b<7;b++){var bw=ri(2,3);block(bx,sy,bw,10,spines[(b+s)%spines.length],shade(spines[(b+s)%spines.length],1.2),shade(spines[(b+s)%spines.length],0.7));bx+=bw; if(bx>x+22)break;} }
    else { R(x+3,sy,10,9,"#20283a"); R(x+4,sy+1,8,3,"#3a4a64"); R(x+15,sy+1,7,8,"#5a4030"); } // a box + folder
  }
}
function plantTall(x,y){
  R(x+1,y+22,10,2,rgba("#000000",0.3));                  // shadow
  block(x+2,y+18,8,8,"#b05a34","#cf7a4a","#7a3c22");     // pot
  R(x+3,y+18,6,1,"#3a2416");                             // soil
  // fronds
  var gr=["#2f7d3a","#3fa04d","#57c065","#256b2f"];
  leaf(x+6,y+18,-1,-9,gr); leaf(x+6,y+18,1,-11,gr); leaf(x+6,y+18,-4,-6,gr); leaf(x+6,y+18,4,-7,gr); leaf(x+6,y+18,0,-14,gr);
}
function leaf(x,y,dx,dy,gr){
  var steps=Math.max(Math.abs(dx),Math.abs(dy));
  for(var i=0;i<=steps;i++){var t=i/steps;R(Math.round(x+dx*t),Math.round(y+dy*t),1,2,gr[i%gr.length]);}
  R(Math.round(x+dx),Math.round(y+dy)-1,2,2,gr[2]);
}
function plantSmall(x,y){
  block(x+1,y+6,7,6,"#c98a4a","#e0a860","#8a5a2a");      // pot
  R(x+2,y+6,5,1,"#3a2416");
  R(x+2,y+2,1,5,"#3fa04d"); R(x+4,y+1,1,6,"#57c065"); R(x+6,y+3,1,4,"#2f7d3a"); R(x+3,y,1,3,"#57c065");
}
function plantHang(x,y){
  R(x+3,y,1,4,"#3a4a64");                                // hook line
  block(x,y+4,8,4,"#3f6f8a","#5a8fa8","#284a5e");        // basket
  R(x+1,y+8,1,3,"#3fa04d"); R(x+3,y+8,1,4,"#57c065"); R(x+5,y+8,1,3,"#2f7d3a"); R(x+6,y+8,1,2,"#3fa04d");
}
function crateStack(x,y,accent){
  crate(x,y+8,accent); crate(x+9,y+8,"#c9a33a"); crate(x+4,y,"#4f9e5a");
}
function crate(x,y,accent){
  block(x,y,10,8,"#6e4a2a","#8a5c34","#4a3018");
  R(x+2,y+3,6,1,rgba(accent,0.7)); R(x+2,y+2,1,4,"#3a2416"); R(x+7,y+2,1,4,"#3a2416");
}
function chair(x,y,dir){
  block(x,y+4,8,3,"#26304a","#36445f","#161e2e");        // seat
  if(dir==="up") block(x+1,y,6,5,"#2c3750","#3c4a68","#1a2234");
  else block(x+1,y+6,6,3,"#2c3750","#3c4a68","#1a2234");
  R(x+1,y+7,1,3,"#161e2e"); R(x+6,y+7,1,3,"#161e2e");
}
function tableRound(x,y){
  R(x+2,y+9,16,3,rgba("#000000",0.28));
  block(x,y,20,10,"#3a2a1a","#5a4028","#241608");
  R(x+2,y+2,16,3,"#4a3420");
}
function rug(x,y,w,h,c1,c2){
  R(x,y,w,h,shade(c1,0.8));
  R(x+2,y+2,w-4,h-4,c1);
  R(x+4,y+4,w-8,h-8,shade(c1,1.15));
  R(x+6,y+6,w-12,h-12,c2);
  // corner ticks
  R(x+1,y+1,2,2,shade(c1,1.3)); R(x+w-3,y+1,2,2,shade(c1,1.3)); R(x+1,y+h-3,2,2,shade(c1,1.3)); R(x+w-3,y+h-3,2,2,shade(c1,1.3));
}
function coffeeMachine(x,y){
  block(x,y,12,18,"#232a3a","#343d52","#141a26");
  R(x+2,y+2,8,5,"#0e1626"); R(x+3,y+3,6,2,rgba("#f7bd4e",0.7));  // display
  R(x+3,y+9,6,4,"#12182a"); R(x+4,y+13,4,2,"#3a2a1a");           // spout + pot
  R(x+2,y+9,1,3,"#3a465e");
}
function waterCooler(x,y){
  block(x+1,y+6,10,14,"#e8f0f6","#ffffff","#b8c6d4");
  block(x+2,y,8,8,"#5aa0d0","#7cc0e6","#3a78a8");               // bottle
  R(x+3,y+1,4,5,rgba("#bfe6ff",0.8));
  R(x+3,y+12,4,2,"#3a465e");
}
function poster(x,y,hue){
  outline(x,y,16,12); R(x,y,16,12,"#101828");
  R(x+2,y+2,12,8,shade(hue,0.6)); R(x+2,y+2,12,1,hue);
  R(x+4,y+5,8,1,shade(hue,1.3)); R(x+4,y+7,6,1,shade(hue,1.1));
}
function wallClock(x,y){
  R(x,y,9,9,OL); R(x+1,y+1,7,7,"#dfe6ef"); R(x+4,y+4,1,1,"#1a2234");
  R(x+4,y+2,1,3,"#2a3446"); R(x+4,y+4,3,1,"#2a3446");
}
function wallVent(x,y){
  block(x,y,18,6,"#1c2436","#2a3550","#12182a");
  for(var i=0;i<5;i++)R(x+2+i*3,y+2,1,2,"#0c1220");
}
function pipes(x,y,h){
  R(x,y,3,h,"#2a3550"); R(x,y,1,h,"#3a4a64"); R(x+2,y,1,h,"#1a2436");
  R(x-1,y+8,5,3,"#26344c"); R(x-1,y+h-12,5,3,"#26344c");
}

/* ============================================================
   ROOM GEOMETRY + BACKGROUND BAKE
   ============================================================ */
var rooms=[], boxes=[], byId={};
function roomRect(ci,riv){return {x:GX[ci]*TILE, y:GY[riv]*TILE, w:RW*TILE, h:RH*TILE};}

function buildRooms(){
  ROOMDEFS.forEach(function(d){
    var r=roomRect(d.g[0],d.g[1]);
    var room={def:d, x:r.x,y:r.y,w:r.w,h:r.h, id:d.id, type:d.type,
      wallH:Math.round(TILE*2.2), racks:[]};
    room.home={x:r.x+r.w/2, y:r.y+r.h-32};
    rooms.push(room);
    if(d.type==="box"||d.type==="triage"){
      var b={ id:d.id, agent:d.agent, role:d.role, color:VENDOR[d.agent], profile:PROFILE[d.agent],
        room:room, x:room.home.x, y:room.home.y, tx:room.home.x, ty:room.home.y,
        face:1, phase:Math.random()*10, blink:0, state:"idle", repo:pick(REPOS),
        timer:ri(1,3), alive:true, bootAt:Date.now()-ri(200000,4000000),
        lastEndTxt:"—", sessions:[], queue:[], picked:[], flash:0, deadT:0 };
      boxes.push(b); byId[b.id]=b; room.box=b;
    }
  });
}

/* bake the whole detailed world into bgCanvas (once) */
var bgCanvas, ambient=[];
function bakeBackground(){
  bgCanvas=document.createElement("canvas"); bgCanvas.width=W; bgCanvas.height=H;
  g=bgCanvas.getContext("2d"); g.imageSmoothingEnabled=false; ambient.length=0;
  drawSubfloor();
  rooms.forEach(function(room){ bakeRoom(room); });
}
function drawSubfloor(){
  R(0,0,W,H,"#05080f");
  for(var gx=0;gx<=COLS;gx+=2)R(gx*TILE,0,1,H,"#080d16");
  for(var gy=0;gy<=ROWS;gy+=2)R(0,gy*TILE,W,1,"#080d16");
  // walkways in the aisles (rooms overdraw)
  var vc=[17.5,35.5], hc=[12.5,25.5];
  vc.forEach(function(c){var x=Math.round(c*TILE);R(x-10,0,20,H,"#0a111d");R(x-10,0,1,H,"#0e1628");R(x+9,0,1,H,"#05090f");for(var y=4;y<H;y+=12)R(x-2,y,4,6,"#111d2e");});
  hc.forEach(function(r){var y=Math.round(r*TILE);R(0,y-10,W,20,"#0a111d");R(0,y-10,W,1,"#0e1628");R(0,y+9,W,1,"#05090f");for(var x=4;x<W;x+=12)R(x,y-2,6,4,"#111d2e");});
}

/* floor + walls shared by every room */
function bakeShell(room,floorA,floorB,accent){
  var x=room.x,y=room.y,w=room.w,h=room.h;
  // drop shadow
  R(x+4,y+6,w,h,rgba("#000000",0.45));
  // floor
  for(var cx=0;cx<RW;cx++)for(var cy=0;cy<RH;cy++){
    var f=((cx+cy)%2===0)?floorA:floorB;
    R(x+cx*TILE,y+cy*TILE,TILE,TILE,f);
    R(x+cx*TILE,y+cy*TILE,TILE,1,shade(f,1.05)); R(x+cx*TILE,y+cy*TILE,1,TILE,shade(f,1.03));
  }
  // platform bevel
  R(x,y,w,1,shade(floorA,1.6)); R(x,y,1,h,shade(floorA,1.35));
  R(x,y+h-1,w,1,"#05080f"); R(x+w-1,y,1,h,"#070b12");
  // back wall
  var wh=room.wallH;
  R(x,y,w,wh,"#2b3145");
  for(var p2=0;p2<RW;p2++){R(x+p2*TILE,y,1,wh,"#242a3c");R(x+p2*TILE+TILE/2,y+3,1,wh-6,"#30374d");} // panel seams
  R(x,y,w,1,"#3c445e"); R(x,y+2,w,1,"#202635");
  R(x,y+wh-2,w,2, accent? shade(accent,0.7):"#1a1f2c");   // accent rail under wall
  if(accent)R(x,y+wh-2,w,1,accent);
  R(x,y+wh,w,2,"#151a26");                                // baseboard
  ambient.push({x:x+w/2,y:y+h*0.55,r:Math.max(w,h)*0.62,c:accent||"#3a5a80",i:accent?0.14:0.12});
}

function bakeRoom(room){
  if(room.type==="box"||room.type==="triage"){ bakeBoxRoom(room); }
  else if(room.type==="operator"){ bakeOperator(room); }
  else { bakeLounge(room); }
}

function bakeBoxRoom(room){
  var b=room.box, vc=b.color;
  var floorA=mix("#1f2739",vc,0.06), floorB=mix("#1a2233",vc,0.05);
  bakeShell(room,floorA,floorB,vc);
  var x=room.x,y=room.y,w=room.w,h=room.h;
  // ALL repo racks along the back wall
  var n=REPOS.length, rackW=22, gap=(w-8-n*rackW)/(n-1), rx=x+4, ry=y+room.wallH-6;
  room.racks=[];
  REPOS.forEach(function(repo,i){
    var pos=repoRack(Math.round(rx),ry,repo, false);
    room.racks.push({repo:repo, x:pos.x, y:pos.y, sx:Math.round(rx)+3, sy:ry+8});
    rx+=rackW+gap;
  });
  cableTray(x+6,ry+44,w-12,vc);
  // wall decor
  wallVent(x+w/2-9,y+4); wallClock(x+w-16,y+5);
  plantHang(x+8, y+2); plantHang(x+w-24, y+2);
  // workstation against the back wall, under the racks
  var wsx=Math.round(x+w/2)-23, wsy=y+room.wallH+46;
  room.deskScreens=[{x:wsx+3+2,y:wsy+2+2},{x:wsx+25+2,y:wsy+2+2}];
  workstation(wsx,wsy,vc);
  chair(wsx+21, wsy+22, "up");                      // empty chair at the desk
  room.wsx=wsx; room.wsy=wsy;
  // the robot's work spot: a rug out in front (kept clear of the desk)
  var hx=Math.round(room.home.x), hy=Math.round(room.home.y);
  rug(hx-27,hy-28,54,38, mix("#2a3450",vc,0.28), shade(vc,0.55));
  // side furniture, tucked to the edges (clear of the racks + centre rug)
  crateStack(x+7, y+h-30, vc);
  shelf(x+w-32, y+h-46);
  plantTall(x+7, y+h-62);
  plantSmall(x+w-13, y+h-40);
  if(room.type==="triage"){ miniBoard(x+w-40, y+h-42); }
}

function miniBoard(x,y){
  outline(x,y,34,24); R(x,y,34,24,"#0a1220");
  R(x+1,y+1,32,22,"#e9edf4"); R(x+1,y+1,32,1,"#ffffff");
  var cols=["#f7bd4e","#5cb4ff","#ff6b6b","#5fce9b"];
  for(var c=0;c<4;c++){R(x+2+c*8,y+2,1,20,"#c3ccd8");R(x+3+c*8,y+3,6,1,cols[c]);
    for(var s=0;s<ri(1,3);s++){R(x+3+c*8+(s%2)*3,y+6+s*4,3,2,cols[c]);}}
}

function bakeOperator(room){
  bakeShell(room,"#242c3e","#1f2739","#5cb4ff");
  var x=room.x,y=room.y,w=room.w,h=room.h;
  // big mission-control desk with 3 monitors showing the fleet
  var dx=x+Math.round(w/2)-33, dy=y+room.wallH+6;
  rug(x+w/2-30,dy+14,60,36,"#243a5a","#1a2a44");
  // monitor bank
  for(var m=0;m<3;m++){ drawBigMonitor(dx+m*23, dy, m); }
  room.opScreens=[{x:dx+3,y:dy+3},{x:dx+26,y:dy+3},{x:dx+49,y:dy+3}];
  // curved desk
  block(dx-3,dy+20,72,9,"#3a2a1a","#5a4028","#241608");
  R(dx,dy+22,66,1,"#4a3420");
  block(dx+24,dy+22,18,3,"#20283a","#2e3850","#141c2c");   // keyboard
  // operator chair (executive)
  block(dx+28,dy+30,12,10,"#1c2436","#2a3550","#12182a");
  R(dx+29,dy+30,10,3,"#243050");
  // notify feed screen on the wall (Telegram merge queue)
  poster(x+8,y+5,"#3fb0e6");
  drawMonitor(x+w-26,y+room.wallH+8,"codex");
  // a lounge nook so the room isn't empty: couch, coffee table, plants
  var cy=y+h-30;
  block(x+w/2-17,cy,34,7,"#3a4a6a","#4c5f86","#242f48");            // couch base
  block(x+w/2-17,cy-6,6,8,"#3a4a6a","#4c5f86","#242f48"); block(x+w/2+11,cy-6,6,8,"#3a4a6a","#4c5f86","#242f48");
  R(x+w/2-10,cy+1,8,3,"#4c5f86"); R(x+w/2+1,cy+1,8,3,"#4c5f86");
  block(x+w/2-8,y+h-16,16,5,"#4a3420","#654a2e","#2c1c10");         // coffee table
  R(x+w/2-5,y+h-14,3,2,"#c0503a"); R(x+w/2+1,y+h-14,3,2,"#3f7fb0");
  // cozy details
  plantTall(x+6, y+h-30); plantSmall(x+w-14,y+h-16);
  shelf(x+w-32,y+h-46); coffeeMachine(x+8,y+h-24); waterCooler(x+w-14,y+room.wallH+6);
  wallClock(x+w/2-4,y+5); wallVent(x+w-46,y+4); plantHang(x+10,y+2); plantHang(x+w-40,y+2);
  ambient.push({x:dx+34,y:dy+10,r:60,c:"#5cb4ff",i:0.2});
}
function drawBigMonitor(x,y,idx){
  block(x,y,21,16,"#0c1220","#22304a","#060a12");
  R(x+2,y+2,17,11,"#0f2438");
  // a tiny live fleet grid on the operator's screen
  for(var a=0;a<3;a++)for(var bb=0;bb<3;bb++){var col=idx===1?["#f7bd4e","#5cb4ff","#5fce9b"][(a+bb)%3]:"#26507a";R(x+3+bb*5,y+3+a*3,3,2,col);}
  R(x+9,y+16,3,2,"#0c1220"); R(x+6,y+18,9,1,"#141c2c");
}

function bakeLounge(room){
  bakeShell(room,"#26303a","#212a34","#5fce9b");         // warmer green-grey commons
  var x=room.x,y=room.y,w=room.w,h=room.h;
  rug(x+w/2-26,y+h/2-16,52,34,"#3a5a4a","#2a4436");
  // couch
  block(x+8,y+h-28,34,7,"#3a4a6a","#4c5f86","#242f48");
  block(x+8,y+h-34,6,8,"#3a4a6a","#4c5f86","#242f48");
  block(x+36,y+h-34,6,8,"#3a4a6a","#4c5f86","#242f48");
  R(x+15,y+h-27,9,3,"#4c5f86"); R(x+26,y+h-27,9,3,"#4c5f86");
  // coffee table + mugs
  block(x+16,y+h-18,18,6,"#4a3420","#654a2e","#2c1c10");
  R(x+20,y+h-16,3,3,"#c0503a"); R(x+27,y+h-16,3,3,"#3f7fb0");
  // big wall TV showing fleet stats
  outline(x+w/2-16,y+6,32,18); R(x+w/2-16,y+6,32,18,"#0a1220"); R(x+w/2-14,y+8,28,14,"#12283e");
  for(var s=0;s<4;s++)R(x+w/2-12,y+10+s*3,ri(8,24),1,["#5fce9b","#5cb4ff","#f7bd4e","#c98bff"][s]);
  // vending machine
  block(x+w-20,y+room.wallH+6,15,30,"#c0503a","#d86a4a","#7a2c1e");
  R(x+w-17,y+room.wallH+9,9,12,"#0e1626"); for(var v=0;v<6;v++)R(x+w-16+(v%3)*3,y+room.wallH+10+Math.floor(v/3)*4,2,3,["#f7bd4e","#5cb4ff","#5fce9b"][v%3]);
  R(x+w-17,y+room.wallH+23,9,3,"#141c2c");
  // plants everywhere (Pokémon commons vibe)
  plantTall(x+6,y+h-30); plantTall(x+w-16,y+h-30); plantSmall(x+8,y+room.wallH+6); plantHang(x+w/2-3,y+2); plantHang(x+w-30,y+2);
  shelf(x+6,y+room.wallH+8);
  wallClock(x+8,y+5); wallVent(x+w/2-9,y+4);
  ambient.push({x:x+w/2,y:y+h/2,r:Math.max(w,h)*0.6,c:"#5fce9b",i:0.12});
}

/* ============================================================
   ROBOT (detailed, per-vendor, outlined)  feet centre (b.x,b.y)
   ============================================================ */
function drawRobot(b){
  var x=Math.round(b.x), y=Math.round(b.y), pr=b.profile, tall=pr.tall||0;
  var moving=Math.abs(b.x-b.tx)>0.6||Math.abs(b.y-b.ty)>0.6;
  var wp=b.phase*10;
  var bob=reduced?0:(moving?Math.round(Math.abs(Math.sin(wp))*2):Math.round(Math.sin(b.phase*2)*0.7));
  var st=STATE[b.state];
  var body=b.alive?b.color:"#565f70";
  body=b.alive?b.color:"#565f70";
  var bodyD=shade(body,0.62), bodyL=shade(body,1.16), head=shade(body,1.24), trim=b.alive?pr.trim:"#818ba0";
  var light=b.alive?st.c:"#ff5c5c";

  // shadow
  g.globalAlpha=0.32; ellip(x,y+1,9,3,"#04070c"); g.globalAlpha=1;
  if(!b.alive){ drawDead(b,x,y); return; }

  var fy=y-bob;
  // legs
  var sw=moving&&!reduced?Math.sin(wp):0;
  legPart(x-4, fy-6+(sw>0?-1:0), body,bodyD);
  legPart(x+1, fy-6+(sw<0?-1:0), body,bodyD);

  // torso (outlined, panelled)
  var th=13+tall;
  outline(x-6,fy-8-th,12,th);
  R(x-6,fy-8-th,12,th,body);
  R(x-6,fy-8-th,12,2,bodyL);                     // top light
  R(x-6,fy-8-th,2,th,bodyL);                     // left light
  R(x+4,fy-8-th,2,th,bodyD);                     // right shade
  R(x-6,fy-10,12,2,bodyD);
  // trim seams + belt
  R(x-6,fy-8-Math.round(th/2),12,1,shade(body,0.75));
  R(x-6,fy-12,12,1,rgba(trim,0.6));
  R(x-4,fy-16,8,1,rgba(trim,0.5));
  // chest screen (state)
  var pulse=reduced?1:(0.55+0.45*Math.sin(b.phase*4));
  block(x-3,fy-8-th+3,6,5,"#0b1119",shade(light,0.6),"#060a12");
  R(x-2,fy-8-th+4,4,3,rgba(light,0.65+0.3*pulse));
  R(x-2,fy-8-th+4,4,1,rgba(light,0.9));
  // shoulder trims
  R(x-6,fy-8-th+1,2,1,trim); R(x+4,fy-8-th+1,2,1,trim);

  // arms + tool
  var armSw=moving&&!reduced?Math.round(Math.sin(wp)*2):0;
  var work=(b.state==="building"||b.state==="reviewing"||b.state==="triaging");
  var toolA=work&&!reduced?Math.round(Math.sin(b.phase*11)*2):0;
  armPart(x-8, fy-8-th+3+(moving?armSw:0), body,bodyD,trim);
  armPart(x+6, fy-8-th+3+(work?toolA:-armSw), body,bodyD,trim);
  drawTool(b,x,fy,toolA,light);

  // head
  var hy=fy-8-th-8;
  outline(x-4,hy,8,8);
  if(pr.head==="square"){ R(x-4,hy,8,8,head); }
  else { R(x-4,hy+1,8,7,head); R(x-3,hy,6,1,head); R(x-4,hy+1,1,1,OL); R(x+3,hy+1,1,1,OL); }
  R(x-4,hy+1,8,1,shade(body,1.4)); R(x-4,hy+1,1,6,bodyL); R(x+3,hy+1,1,6,bodyD);
  if(pr.ears===2){ R(x-4,hy-2,2,3,head); R(x-4,hy-2,1,3,OL); R(x+2,hy-2,2,3,head); R(x+3,hy-2,1,3,OL); R(x-3,hy-1,1,1,rgba(trim,0.8)); R(x+3,hy-1,1,1,rgba(trim,0.8)); }
  // face
  R(x-3,hy+3,6,3,"#0a0f18");                     // visor recess
  if(pr.eyes==="visor"){ R(x-3,hy+4,6,1,b.blink>0?"#0a0f18":light); }
  else if(pr.eyes==="cyclops"){ if(b.blink<=0){R(x-2,hy+4,4,1,light);R(x-1,hy+3,2,1,rgba(light,0.7));} }
  else { if(b.blink<=0){R(x-2,hy+4,2,1,light);R(x+1,hy+4,1,1,light);} }
  R(x-3,hy+3,6,1,rgba(trim,0.4));                // brow trim
  // antenna
  if(pr.antenna==="ball"){R(x,hy-3,1,3,shade(body,0.7));var bl=reduced?1:(Math.sin(b.phase*6)>-0.3?1:0.35);g.globalAlpha=bl;R(x-1,hy-5,2,2,light);g.globalAlpha=1;}
  else if(pr.antenna==="rod"){R(x,hy-4,1,4,shade(body,0.7));R(x,hy-4,1,1,light);}

  // triage CALL — holo panel beside the head (stays in quarters)
  if(b.state==="triaging"){ drawCallHolo(x+9, fy-8-th-2, b); }
  // prompt ping
  if(b.flash>0){g.globalAlpha=b.flash;R(x-1,hy-8,2,4,"#8fe0ff");R(x-2,hy-6,4,1,"#8fe0ff");g.globalAlpha=1;pushLight(x,hy-6,22,"#8fe0ff",b.flash*0.8);}

  pushLight(x, fy-14, 30, light, b.state==="idle"?0.16:0.34);
}
function legPart(x,y,body,bodyD){ outline(x,y,3,7); R(x,y,3,7,bodyD); R(x,y,1,7,shade(body,0.8)); R(x-1,y+6,5,2,"#0a0f18"); R(x,y+6,3,1,shade(body,0.4)); }
function armPart(x,y,body,bodyD,trim){ outline(x,y,3,7); R(x,y,3,7,body); R(x,y,1,7,shade(body,1.1)); R(x,y+2,3,1,rgba(trim,0.4)); R(x,y+6,3,2,shade(body,0.7)); }
function drawTool(b,x,fy,toolA,light){
  var hx=x+8, hy=fy-8-(9)+toolA-3;
  if(b.state==="building"){ // wrench/hammer
    R(hx,hy,2,7,"#7a8496"); R(hx-1,hy-1,4,3,"#c9d5e6"); R(hx-1,hy-1,4,1,"#e6eef7");
  } else if(b.state==="reviewing"){ // magnifier
    outline(hx,hy,5,5); R(hx,hy,5,5,"#0b1119"); R(hx+1,hy,3,1,light); R(hx,hy+1,1,3,light); R(hx+4,hy+1,1,3,light); R(hx+1,hy+4,3,1,light); R(hx+4,hy+5,3,3,"#7a8496");
  } else if(b.state==="triaging"){ // tablet held up (calling)
    outline(hx,hy,5,7); R(hx,hy,5,7,"#0c1626"); R(hx+1,hy+1,3,5,rgba("#c98bff",0.7)); R(hx+1,hy+1,3,1,"#d9b6ff");
  }
}
function drawCallHolo(x,y,b){
  var pulse=0.6+0.4*Math.sin(b.phase*5);
  // beam
  g.globalAlpha=0.5*pulse; R(x-2,y+6,2,2,"#c98bff"); g.globalAlpha=1;
  // floating panel (mini kanban)
  outline(x,y-6,16,12); g.globalAlpha=0.9; R(x,y-6,16,12,rgba("#101a2e",0.85)); g.globalAlpha=1;
  R(x,y-6,16,1,"#c98bff");
  var cols=["#f7bd4e","#5cb4ff","#ff6b6b","#5fce9b"];
  for(var c=0;c<4;c++){ R(x+2+c*3.5,y-4,1,8,"#2a3550"); R(x+2+c*3.5,y-3,2,1,cols[c]); if((c+Math.floor(b.phase*2))%2===0)R(x+2+c*3.5,y-1,2,1,rgba(cols[c],0.8)); }
  pushLight(x+8,y,20,"#c98bff",0.3);
}
function drawDead(b,x,y){
  var flick=(!reduced&&Math.floor(b.phase*20)%5===0)?1:0;
  outline(x-7,y-7,14,6); R(x-7,y-7,14,6,"#3d4557");
  R(x-7,y-7,14,1,"#4e5870");
  outline(x+5,y-10,7,7); R(x+5,y-10,7,7,"#353c4c");     // head fallen
  R(x+6,y-9,1,1,"#ff5c5c");R(x+9,y-9,1,1,"#ff5c5c");R(x+7,y-8,1,1,"#ff5c5c");R(x+8,y-8,1,1,"#ff5c5c");R(x+6,y-7,1,1,"#ff5c5c");R(x+9,y-7,1,1,"#ff5c5c");
  if(flick){R(x-1,y-14,2,4,"#ff7a7a");R(x-1,y-9,2,1,"#ff7a7a");spawnSpark(x,y-6,"#ff5c5c",true);}
  pushLight(x,y-4,28,"#ff3b3b",0.26+(flick?0.24:0));
}
function ellip(cx,cy,rx,ry,col){for(var yy=-ry;yy<=ry;yy++){var ww=Math.round(rx*Math.sqrt(Math.max(0,1-(yy*yy)/(ry*ry))));R(cx-ww,cy+yy,ww*2,1,col);}}

/* ============================================================
   DYNAMIC OVERLAYS (live glow that can't be baked)
   ============================================================ */
var sparks=[], packets=[], lights=[];
function pushLight(x,y,r,c,i){lights.push({x:x,y:y,r:r,c:c,i:i});}
function spawnSpark(x,y,c,up){sparks.push({x:x,y:y,vx:rnd(-0.5,0.5),vy:up?rnd(-1.4,-0.6):rnd(-0.3,0.3),life:rnd(0.4,0.9),c:c});}
function stepSparks(dt){for(var i=sparks.length-1;i>=0;i--){var s=sparks[i];s.x+=s.vx;s.y+=s.vy;s.vy+=0.05;s.life-=dt;if(s.life<=0)sparks.splice(i,1);}}
function stepPackets(dt){
  if(packets.length<boxes.length&&chance(0.05)){var b=pick(boxes);if(b.alive){var room=b.room;packets.push({x:room.x+8,y:room.y+room.wallH+42,vx:rnd(14,26),max:room.x+room.w-8,c:rgba(b.color,0.9)});}}
  for(var i=packets.length-1;i>=0;i--){var k=packets[i];k.x+=k.vx*dt;if(k.x>k.max)packets.splice(i,1);}
}
function drawDynamic(){
  lights.length=0;
  ambient.forEach(function(a){lights.push(a);});
  // live monitor + active-rack glow per room
  boxes.forEach(function(b){
    var room=b.room, working=b.alive&&(b.state==="building"||b.state==="reviewing");
    // desk monitors always softly lit; brighter when working
    if(room.deskScreens){room.deskScreens.forEach(function(sc){
      var col=b.alive?(working?STATE[b.state].c:"#3a78b0"):"#5a3a3a";
      var ph=Math.floor(b.phase*4);
      R(sc.x, sc.y+(ph%6), 8,1, rgba(col,0.7));
      pushLight(sc.x+7, sc.y+4, working?24:14, col, working?0.4:0.16);
    });}
    // active repo rack glow + a glow on the work rug
    if(working){
      var c=STATE[b.state].c;
      var rk=null; room.racks.forEach(function(r){if(r.repo===b.repo)rk=r;});
      if(rk){
        R(rk.sx,rk.sy-2,16,2,rgba(c,0.85));
        pushLight(rk.x,rk.y-6,42,c,0.8);
        if(!reduced&&chance(0.25))spawnSpark(rk.x,rk.y-34,c,true);
      }
      pushLight(b.x,b.y-16,40,c,0.4);   // pool under the working bot
    }
  });
  // sparks + packets
  sparks.forEach(function(s){g.globalAlpha=clamp(s.life,0,1);R(Math.round(s.x),Math.round(s.y),1,1,s.c);});g.globalAlpha=1;
  packets.forEach(function(k){R(Math.round(k.x),Math.round(k.y),3,1,k.c);});
  // robots (depth sorted)
  boxes.slice().sort(function(a,c){return a.y-c.y;}).forEach(function(b){drawRobot(b);});
  if(hoverId){var hb=byId[hoverId];if(hb)ring(hb.x,hb.y-14,hb.state?STATE[hb.state].c:"#fff");}
}
function ring(x,y,col){R(x-11,y-13,22,1,col);R(x-11,y+12,22,1,col);R(x-12,y-12,1,25,col);R(x+11,y-12,1,25,col);}

/* ============================================================
   ATMOSPHERE (full-res, over the crisp blit)
   ============================================================ */
function drawAtmosphere(){
  vctx.save(); vctx.globalCompositeOperation="lighter";
  lights.forEach(function(L){var s=artToScreen(L.x,L.y),r=L.r*scale;var gr=vctx.createRadialGradient(s.x,s.y,0,s.x,s.y,r);gr.addColorStop(0,rgba(L.c,0.5*L.i));gr.addColorStop(0.5,rgba(L.c,0.15*L.i));gr.addColorStop(1,"rgba(0,0,0,0)");vctx.fillStyle=gr;vctx.beginPath();vctx.arc(s.x,s.y,r,0,7);vctx.fill();});
  dust.forEach(function(d){vctx.fillStyle="rgba(150,180,220,"+(0.05+0.09*d.z)+")";vctx.fillRect(d.x*vw,d.y*vh,d.z<0.6?1:1.5,d.z<0.6?1:1.5);});
  vctx.restore();
  var vg=vctx.createRadialGradient(vw/2,vh/2,Math.min(vw,vh)*0.36,vw/2,vh/2,Math.max(vw,vh)*0.74);
  vg.addColorStop(0,"rgba(0,0,0,0)");vg.addColorStop(1,"rgba(3,6,12,0.7)");vctx.fillStyle=vg;vctx.fillRect(0,0,vw,vh);
  if(scanPat){vctx.fillStyle=scanPat;vctx.globalAlpha=0.45;vctx.fillRect(0,0,vw,vh);vctx.globalAlpha=1;}
}
var dust=[];for(var dm=0;dm<70;dm++)dust.push({x:Math.random(),y:Math.random(),z:rnd(.3,1),vy:rnd(.002,.01),vx:rnd(-.004,.004)});
function stepDust(dt){dust.forEach(function(d){d.y-=d.vy;d.x+=d.vx;if(d.y<0){d.y=1;d.x=Math.random();}if(d.x<0)d.x=1;if(d.x>1)d.x=0;});}
var scanPat=null;
function buildScanPattern(){var c=document.createElement("canvas");c.width=1;c.height=3;var cx=c.getContext("2d");cx.fillStyle="rgba(0,0,0,0.5)";cx.fillRect(0,2,1,1);scanPat=vctx.createPattern(c,"repeat");}

/* ============================================================
   SIM ENGINE — bots stay in quarters; triage = a call
   ============================================================ */
var TICK_MS=2600, tickCount=0;
function outcomeFor(kind){
  if(kind==="build")return pick(["opened PR","pushed fixups","needs-human","resumed"]);
  if(kind==="review")return pick(["approved","changes-requested","commented","re-request → approved"]);
  if(kind==="triage")return pick(["labeled ready","routed to builder","marked blocked","ruling posted"]);
  return "ok";
}
function startSession(b,forceKind){
  var kind=forceKind||STATE[b.state].kind; b.repo=pick(REPOS);
  var key=(kind==="triage")?"board":issueKey(b.repo);
  logLine(b,"k-"+(kind==="build"?"build":kind==="review"?"review":"triage"),"SESSION START kind="+kind+" key="+key+" timeout="+(kind==="build"?1200:600)+"s");
  b.sessions.unshift({t:nowClock(),txt:"START "+kind+" "+key,cls:""});b.sessions=b.sessions.slice(0,6);
}
function endSession(b){
  var kind=STATE[b.state].kind;if(kind==="idle"||kind==="dead")return;
  var rc=chance(0.12)?1:0,dur=ri(18,140),out=rc?"aborted (budget)":outcomeFor(kind);
  b.lastEndTxt="rc="+rc+" · "+out;
  logLine(b,"k-"+(kind==="build"?"build":kind==="review"?"review":"triage"),"SESSION END kind="+kind+" rc="+rc+" dur="+dur+"s outcome="+out,rc?"cr":"ok");
  b.sessions.unshift({t:nowClock(),txt:"END "+kind+" "+out,cls:rc?"warn":"ok"});b.sessions=b.sessions.slice(0,6);
}
function setState(b,st){
  if(b.state===st)return;
  if(b.state==="building"||b.state==="reviewing"||b.state==="triaging")endSession(b);
  b.state=st;
  if(st==="building"||st==="reviewing"||st==="triaging"){ b.tx=b.room.home.x; b.ty=b.room.home.y; startSession(b); }
  else if(st==="idle"){ wander(b); }
}
function wander(b){var room=b.room;b.tx=room.x+rnd(room.w*0.25,room.w*0.75);b.ty=room.y+rnd(room.h*0.55,room.h*0.86);}
function tick(){
  tickCount++;
  boxes.forEach(function(b){
    if(!b.alive){
      if(chance(0.22)){b.alive=true;b.bootAt=Date.now();b.deadT=0;b.state="idle";wander(b);logLine(b,"k-boot","boot: gh ✓ box ✓ — on duty");if(inspFor===b.id)refreshInspector();}
      else if(tickCount%2===0)logLine(b,"k-dead","⚠ no evidence line — cron silent");
      return;
    }
    if(b.queue.length){
      var q=b.queue.shift();q.picked=true;q.pickedAt=nowClock();b.flash=1;b.picked.push(q);
      logLine(b,"k-prompt","📨 operator prompt picked up → kind="+(b.role==="triage"?"triage":b.role==="builder"?"build":"review"));
      setState(b,b.role==="triage"?"triaging":b.role==="builder"?"building":"reviewing");b.timer=ri(2,4);
      if(inspFor===b.id){renderQueue(b);refreshInspector();}
      return;
    }
    if(chance(0.02)){endSession(b);b.alive=false;b.state="dead";logLine(b,"k-dead","⚠ tick boundary missed — box unreachable");if(inspFor===b.id)refreshInspector();return;}
    b.timer--;
    if(b.timer>0){if(b.state==="idle"&&chance(0.5))wander(b);return;}
    var r=Math.random(),next;
    if(b.role==="triage")next=r<0.62?"triaging":"idle";
    else if(b.role==="builder")next=r<0.5?"building":r<0.68?"triaging":"idle";
    else next=r<0.5?"reviewing":r<0.68?"triaging":"idle";
    setState(b,next);b.timer=next==="idle"?ri(1,3):ri(2,5);
  });
  updateRoster();if(inspOpen)refreshInspector();
}

/* ============================================================
   MAIN LOOP + blit
   ============================================================ */
var view=document.getElementById("view"), vctx=view.getContext("2d");
var buf=document.createElement("canvas"); buf.width=W; buf.height=H; var bufctx=buf.getContext("2d"); bufctx.imageSmoothingEnabled=false;
var vw=0,vh=0,scale=1,ox=0,oy=0,dpr=1,lastT=0;
function frame(t){
  var dt=Math.min(0.05,(t-lastT)/1000)||0.016;lastT=t;
  boxes.forEach(function(b){
    b.phase+=dt;
    if(b.flash>0)b.flash=Math.max(0,b.flash-dt*1.4);
    if(b.blink>0)b.blink-=dt;else if(!reduced&&chance(0.004))b.blink=0.12;
    if(!b.alive){b.deadT+=dt;return;}
    var dx=b.tx-b.x,dy=b.ty-b.y,d=Math.hypot(dx,dy);
    if(d>0.6){var sp=(reduced?70:26)*dt,m=Math.min(sp,d);b.x+=dx/d*m;b.y+=dy/d*m;b.face=dx<0?-1:1;}else{b.x=b.tx;b.y=b.ty;}
    if(!reduced){if(b.state==="building"&&chance(0.5))spawnSpark(b.x+8,b.y-16,"#ffcf5a",true);if(b.state==="reviewing"&&chance(0.1))spawnSpark(b.x+9,b.y-16,"#9cccff",true);}
  });
  stepSparks(dt);stepPackets(dt);stepDust(dt);
  // compose: static bg -> dynamic -> blit -> atmosphere
  bufctx.drawImage(bgCanvas,0,0);
  g=bufctx; drawDynamic();
  blit(); drawAtmosphere();
  requestAnimationFrame(frame);
}
function resize(){
  var host=document.getElementById("floor"),r=host.getBoundingClientRect();
  dpr=Math.min(2,window.devicePixelRatio||1);vw=r.width;vh=r.height;
  view.width=Math.floor(vw*dpr);view.height=Math.floor(vh*dpr);
  scale=Math.max(1,Math.min(vw/W,vh/H));
  ox=Math.round((vw-W*scale)/2);oy=Math.round((vh-H*scale)/2);
  vctx.setTransform(dpr,0,0,dpr,0,0);vctx.imageSmoothingEnabled=false;
  buildScanPattern();layoutLabels();
}
function blit(){vctx.fillStyle="#05080f";vctx.fillRect(0,0,vw,vh);vctx.imageSmoothingEnabled=false;vctx.drawImage(buf,0,0,W,H,ox,oy,W*scale,H*scale);}
function artToScreen(ax,ay){return {x:ox+ax*scale,y:oy+ay*scale};}
function screenToArt(sx,sy){return {x:(sx-ox)/scale,y:(sy-oy)/scale};}

/* ---------- DOM room labels ---------- */
var labelEls={};
function buildLabels(){
  var floor=document.getElementById("floor");
  rooms.forEach(function(room){
    var name, sub;
    if(room.type==="operator"){name="Operator";sub="mission control";}
    else if(room.type==="lounge"){name="Lounge";sub="the commons";}
    else{name=room.id;sub=room.def.role+(room.type==="triage"?" · board":"");}
    var el=document.createElement("div");el.className="zlabel";el.innerHTML="<b>"+name+"</b> <span class='rl'>· "+sub+"</span>";
    floor.appendChild(el);labelEls[room.id]={el:el,room:room};
  });
}
function layoutLabels(){for(var id in labelEls){var L=labelEls[id];var pt=artToScreen(L.room.x+4,L.room.y+L.room.h-13);L.el.style.left=pt.x+"px";L.el.style.top=pt.y+"px";}}

/* ============================================================
   HUD (roster, ticker, tooltip, inspector)
   ============================================================ */
var rosterEl=document.getElementById("roster");
function buildRoster(){
  boxes.forEach(function(b){
    var row=document.createElement("div");row.className="rrow";row.dataset.id=b.id;
    row.innerHTML="<span class='av' style='background:"+b.color+"'></span><span class='who'><span class='nm'>"+b.id+"</span><span class='role'>"+b.agent+" · "+b.role+"</span></span><span class='chip'></span>";
    row.addEventListener("click",function(){focusBox(b.id);});rosterEl.appendChild(row);
  });updateRoster();
}
function updateRoster(){boxes.forEach(function(b){var row=rosterEl.querySelector("[data-id='"+b.id+"']");if(!row)return;var chip=row.querySelector(".chip"),st=STATE[b.state];chip.textContent=st.label;chip.style.color=st.c;chip.style.background=shade(st.c,0.16);chip.style.borderColor=shade(st.c,0.4);row.classList.toggle("sel",inspFor===b.id);});}
var logEl=document.getElementById("log");
function logLine(b,cls,msg,extra){var l=document.createElement("div");l.className="l "+cls;var m=msg;if(extra==="ok")m=msg.replace(/outcome=([^\s]+.*)$/,"outcome=<span class='ok'>$1</span>");if(extra==="cr")m=msg.replace(/rc=1/,"<span class='cr'>rc=1</span>");l.innerHTML="<span class='t'>"+nowClock()+"</span><span class='b'>"+b.id+"</span><span class='m'>"+m+"</span>";logEl.appendChild(l);while(logEl.childNodes.length>80)logEl.removeChild(logEl.firstChild);logEl.scrollTop=logEl.scrollHeight;}
var tip=document.getElementById("tip");
function showTip(b,sx,sy){tip.querySelector(".t1").textContent=b.id;tip.querySelector(".t2").textContent=b.alive?(STATE[b.state].label+" · "+b.repo):"Disconnected · cron silent";tip.style.left=sx+"px";tip.style.top=sy+"px";tip.style.opacity="1";}
function hideTip(){tip.style.opacity="0";}
var inspEl=document.getElementById("inspector"),inspOpen=false,inspFor=null;
function openInspector(id){inspFor=id;inspOpen=true;inspEl.classList.add("open");refreshInspector();updateRoster();}
function closeInspector(){inspOpen=false;inspFor=null;inspEl.classList.remove("open");updateRoster();}
function fmtUptime(ms){if(ms<0)ms=0;var s=Math.floor(ms/1000),h=Math.floor(s/3600),m=Math.floor((s%3600)/60),ss=s%60;return (h?h+"h ":"")+pad(m)+"m "+pad(ss)+"s";}
function refreshInspector(){
  var b=byId[inspFor];if(!b)return;
  document.getElementById("insp-id").textContent=b.id;
  document.getElementById("insp-meta").textContent=b.agent+" · "+b.role;
  document.getElementById("insp-badge").style.background=shade(b.color,0.22);drawAvatar(b);
  var st=STATE[b.state],vs=document.getElementById("v-status");vs.textContent=st.label;vs.style.color=st.c;
  document.getElementById("v-uptime").textContent=b.alive?fmtUptime(Date.now()-b.bootAt):"—";
  document.getElementById("v-repo").textContent=b.alive?b.repo:"—";
  document.getElementById("v-tick").textContent=b.alive?"≤5m ago":"silent";
  var tl=document.getElementById("v-timeline");tl.innerHTML="";
  if(!b.sessions.length)tl.innerHTML="<div class='ln'><span class='tk'>—</span>no sessions yet</div>";
  b.sessions.forEach(function(s){var ln=document.createElement("div");ln.className="ln";ln.innerHTML="<span class='tk'>"+s.t+"</span><span class='"+(s.cls||"")+"'>"+s.txt+"</span>";tl.appendChild(ln);});
  renderQueue(b);
}
function renderQueue(b){var q=document.getElementById("queue");q.innerHTML="";b.queue.forEach(function(item){q.appendChild(qEl(item,false));});(b.picked||[]).slice(-2).forEach(function(item){q.appendChild(qEl(item,true));});}
function qEl(item,picked){var d=document.createElement("div");d.className="qitem"+(picked?" picked":"");d.innerHTML="<div class='qs'>"+(picked?"picked up "+item.pickedAt:"queued "+item.at+" · waiting for next tick")+"</div>"+escapeHtml(item.text);return d;}
function escapeHtml(s){return s.replace(/[&<>]/g,function(c){return c==="&"?"&amp;":c==="<"?"&lt;":"&gt;";});}
var avEl=document.getElementById("insp-av"),avc=avEl.getContext("2d");
function drawAvatar(b){avc.imageSmoothingEnabled=false;avc.clearRect(0,0,34,34);var mini=document.createElement("canvas");mini.width=22;mini.height=30;var mp=mini.getContext("2d");var og=g;g=mp;var sx=b.x,sy=b.y,stx=b.tx,sty=b.ty;b.x=11;b.y=28;b.tx=11;b.ty=28;var of=b.flash;b.flash=0;drawRobot(b);b.x=sx;b.y=sy;b.tx=stx;b.ty=sty;b.flash=of;g=og;avc.drawImage(mini,0,0,22,30,3,1,22*1.1,30*1.1);}

/* ---------- interaction ---------- */
var hoverId=null;
function hitRobot(ax,ay){var best=null,bd=1e9;boxes.forEach(function(b){var dx=ax-b.x,dy=ay-(b.y-14),d=dx*dx+dy*dy;if(d<bd&&Math.abs(dx)<12&&dy>-22&&dy<14){bd=d;best=b;}});return best;}
view.addEventListener("mousemove",function(e){var r=view.getBoundingClientRect(),a=screenToArt(e.clientX-r.left,e.clientY-r.top),b=hitRobot(a.x,a.y);if(b){hoverId=b.id;view.style.cursor="pointer";var pt=artToScreen(b.x,b.y-30);showTip(b,pt.x,pt.y);}else{hoverId=null;hideTip();view.style.cursor="default";}});
view.addEventListener("mouseleave",function(){hoverId=null;hideTip();});
view.addEventListener("dblclick",function(e){var r=view.getBoundingClientRect(),a=screenToArt(e.clientX-r.left,e.clientY-r.top),b=hitRobot(a.x,a.y);if(b)openInspector(b.id);});
function focusBox(id){var b=byId[id];if(!b)return;openInspector(id);b.flash=1;}
document.getElementById("insp-close").addEventListener("click",closeInspector);
document.getElementById("prompt-send").addEventListener("click",sendPrompt);
document.getElementById("prompt-in").addEventListener("keydown",function(e){if((e.metaKey||e.ctrlKey)&&e.key==="Enter")sendPrompt();});
function sendPrompt(){var b=byId[inspFor];if(!b)return;var ta=document.getElementById("prompt-in"),txt=ta.value.trim();if(!txt)return;if(!b.alive){var q=document.getElementById("queue");var w=document.createElement("div");w.className="qitem";w.style.borderLeftColor="var(--dead)";w.innerHTML="<div class='qs' style='color:var(--dead)'>undeliverable</div>Box is disconnected — no tick to drain the channel. Message not queued.";q.prepend(w);return;}b.queue.push({text:txt,at:nowClock(),picked:false});ta.value="";renderQueue(b);}
var aboutBg=document.getElementById("about-bg");
document.getElementById("about-btn").addEventListener("click",function(){aboutBg.classList.add("open");});
document.getElementById("about-close").addEventListener("click",function(){aboutBg.classList.remove("open");});
aboutBg.addEventListener("click",function(e){if(e.target===aboutBg)aboutBg.classList.remove("open");});
document.addEventListener("keydown",function(e){if(e.key==="Escape"){aboutBg.classList.remove("open");if(inspOpen)closeInspector();}});
function tickClock(){document.getElementById("clock").textContent=nowClock();}

/* ---------- boot ---------- */
function init(){
  buildRooms(); bakeBackground(); buildLabels(); buildRoster();
  window.addEventListener("resize",resize); resize();
  boxes.forEach(function(b,i){if(i%3===0){var st=b.role==="builder"?"building":b.role==="reviewer"?"reviewing":"triaging";b.state=st;b.tx=b.room.home.x;b.ty=b.room.home.y;startSession(b);}});
  updateRoster();tickClock();setInterval(tickClock,1000);setInterval(tick,TICK_MS);requestAnimationFrame(frame);
}
init();
})();
