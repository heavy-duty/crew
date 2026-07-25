"use strict";
(function(){
/* ============================================================
   Fleet Floor — pixel god-view of heavy-duty/crew (simulated feed)
   Crisp pixel world drawn to an offscreen buffer, blitted
   nearest-neighbour, then a full-res lighting/atmosphere pass on top.
   ============================================================ */

var TILE = 10, COLS = 66, ROWS = 42;
var W = COLS*TILE, H = ROWS*TILE;               // 660 x 420 art px
var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

var VENDOR = { claude:"#f6a04d", codex:"#3ad6a4", grok:"#b07cff", kimi:"#ff72b6" };
var STATE = {
  building:{c:"#f7bd4e", label:"Building",     kind:"build"},
  reviewing:{c:"#5cb4ff", label:"Reviewing",   kind:"review"},
  triaging:{c:"#c98bff", label:"Triaging",     kind:"triage"},
  idle:{c:"#5fce9b",      label:"Idle",         kind:"idle"},
  dead:{c:"#ff5c5c",      label:"Disconnected", kind:"dead"}
};

/* ---------- 3x3 room grid (office dead-centre) ---------- */
var CX=[[2,20],[23,41],[44,63]];   // column tile spans [c0,c1]
var CY=[[2,13],[16,27],[30,41]];   // row tile spans [r0,r1]
function cell(ci,ri){ return {c0:CX[ci][0],r0:CY[ri][0],c1:CX[ci][1],r1:CY[ri][1]}; }
var OFFICE = cell(1,1);
var ATRIUM = cell(0,1);            // decorative ops-desk / entrance
var BOXDEFS = [
  {id:"claude-triage",  agent:"claude", role:"triage",   g:[0,0], repos:["ceremony","box","crew"]},
  {id:"claude-builder", agent:"claude", role:"builder",  g:[1,0], repos:["incubator","ceremony","box"]},
  {id:"claude-reviewer",agent:"claude", role:"reviewer", g:[2,0], repos:["cast","rig","ceremony"]},
  {id:"codex-builder",  agent:"codex",  role:"builder",  g:[2,1], repos:["box","incubator","crew"]},
  {id:"codex-reviewer", agent:"codex",  role:"reviewer", g:[2,2], repos:["ceremony","cast"]},
  {id:"grok-reviewer",  agent:"grok",   role:"reviewer", g:[1,2], repos:["rig","ceremony","incubator"]},
  {id:"kimi-reviewer",  agent:"kimi",   role:"reviewer", g:[0,2], repos:["cast","box","ceremony"]}
];

/* ---------- utils ---------- */
function rnd(a,b){ return a + Math.random()*(b-a); }
function ri(a,b){ return Math.floor(rnd(a,b+1)); }
function pick(arr){ return arr[ri(0,arr.length-1)]; }
function chance(p){ return Math.random() < p; }
function clamp(v,a,b){ return v<a?a:(v>b?b:v); }
function hex(h){ h=h.replace("#",""); return [parseInt(h.substr(0,2),16),parseInt(h.substr(2,2),16),parseInt(h.substr(4,2),16)]; }
function shade(h,f){
  var c=hex(h), r,g,b;
  if(f<=1){ r=c[0]*f; g=c[1]*f; b=c[2]*f; }
  else { var t=f-1; r=c[0]+(255-c[0])*t; g=c[1]+(255-c[1])*t; b=c[2]+(255-c[2])*t; }
  return "rgb("+Math.round(clamp(r,0,255))+","+Math.round(clamp(g,0,255))+","+Math.round(clamp(b,0,255))+")";
}
function rgba(h,a){ var c=hex(h); return "rgba("+c[0]+","+c[1]+","+c[2]+","+a+")"; }
function pad(n){ return (n<10?"0":"")+n; }
function nowClock(){ var d=new Date(); return pad(d.getUTCHours())+":"+pad(d.getUTCMinutes())+":"+pad(d.getUTCSeconds()); }
function issueKey(repo){ return repo+"#"+ri(11,148); }

/* ---------- vendor robot profiles ---------- */
var PROFILE = {
  claude:{head:"round", ears:0, antenna:"ball", eyes:"two",   tall:0},
  codex: {head:"square",ears:0, antenna:"rod",  eyes:"visor", tall:0},
  grok:  {head:"round", ears:0, antenna:"rod",  eyes:"cyclops",tall:2},
  kimi:  {head:"round", ears:2, antenna:"none", eyes:"two",   tall:0}
};

/* ---------- runtime boxes ---------- */
var boxes = BOXDEFS.map(function(d,i){
  var z=cell(d.g[0],d.g[1]);
  var cx=(z.c0+z.c1+1)/2;
  var home={x:cx*TILE, y:(z.r1-2.5)*TILE};
  return {
    idx:i, id:d.id, agent:d.agent, role:d.role, repos:d.repos,
    color:VENDOR[d.agent], profile:PROFILE[d.agent], zone:z,
    home:home, x:home.x, y:home.y, tx:home.x, ty:home.y,
    face:1, phase:Math.random()*10, blink:0,
    state:"idle", repo:d.repos[0], timer:ri(1,3), alive:true,
    bootAt:Date.now()-ri(200000,4000000), lastEndTxt:"—", lastKey:"—",
    sessions:[], queue:[], picked:[], flash:0, deadT:0
  };
});
var byId={}; boxes.forEach(function(b){ byId[b.id]=b; });

/* office triage slots (in front of the board) */
var triSlots=[];
for(var s=0;s<4;s++){ triSlots.push({x:(OFFICE.c0+3+s*4)*TILE, y:(OFFICE.r1-2)*TILE}); }
function freeTriSlot(){
  var used={}; boxes.forEach(function(b){ if(b.triSlot!=null) used[b.triSlot]=1; });
  for(var i=0;i<triSlots.length;i++) if(!used[i]) return i;
  return ri(0,triSlots.length-1);
}

/* ---------- particles ---------- */
var sparks=[];
function spawnSpark(x,y,col,up){
  sparks.push({x:x,y:y,vx:rnd(-0.5,0.5),vy:up?rnd(-1.4,-0.6):rnd(-0.3,0.3),life:rnd(0.4,0.9),col:col});
}
function stepSparks(dt){
  for(var i=sparks.length-1;i>=0;i--){ var pp=sparks[i]; pp.x+=pp.vx; pp.y+=pp.vy; pp.vy+=0.05; pp.life-=dt; if(pp.life<=0) sparks.splice(i,1); }
}
/* data packets travel along each room's cable tray */
var packets=[];
/* dust motes (screen-space, filled during lighting pass) */
var dust=[];
for(var dm=0;dm<70;dm++) dust.push({x:Math.random(),y:Math.random(),z:rnd(.3,1),vy:rnd(.002,.01),vx:rnd(-.004,.004)});

/* lights collected each frame, consumed by the atmosphere pass */
var lights=[];
function addLight(ax,ay,r,color,intensity){ lights.push({x:ax,y:ay,r:r,c:color,i:intensity}); }

/* ---------- offscreen buffer ---------- */
var buf=document.createElement("canvas"); buf.width=W; buf.height=H;
var p=buf.getContext("2d"); p.imageSmoothingEnabled=false;
function R(x,y,w,h,col){ p.fillStyle=col; p.fillRect(x|0,y|0,w|0,h|0); }

/* ============================================================
   WORLD  (offscreen, crisp pixels)
   ============================================================ */
function drawWorld(){
  lights.length=0;
  drawSubfloor();
  drawRoom(OFFICE, "#242f48", null, true);   // office platform (neutral)
  drawAtrium();
  boxes.forEach(function(b){ drawRoomFor(b); });
  drawOfficeInterior();
  boxes.forEach(function(b){ drawRoomInterior(b); });
  // scan sweeps behind robots
  boxes.forEach(function(b){ if(b.alive && b.state==="reviewing") drawScan(b); });
  drawSparks();
  drawPackets();
  // robots sorted by depth
  boxes.slice().sort(function(a,c){return a.y-c.y;}).forEach(function(b){ drawRobot(b); });
  if(hoverId){ var hb=byId[hoverId]; if(hb) ringAt(hb.x,hb.y-9,STATE[hb.state].c); }
}

/* dark grated sub-floor */
function drawSubfloor(){
  R(0,0,W,H,"#070b12");
  // faint plate grid
  for(var gx=0;gx<=COLS;gx+=3) R(gx*TILE,0,1,H,"#0a111c");
  for(var gy=0;gy<=ROWS;gy+=3) R(0,gy*TILE,W,1,"#0a111c");
  // a few brighter rivets/vents for texture
  for(var vx=4;vx<COLS;vx+=9) for(var vy=4;vy<ROWS;vy+=9){
    R(vx*TILE+2, vy*TILE+2, 1,1, "#111b2b");
  }
  drawAisles();
}
// facility walkways threading the aisles between rooms (rooms overdraw them)
function drawAisles(){
  var vc=[21.5,42.5], hc=[14.5,28.5];
  vc.forEach(function(c){ var x=Math.round(c*TILE);
    R(x-6,0,12,H,"#0a111c"); R(x-6,0,1,H,"#0d1626"); R(x+5,0,1,H,"#060a11");
    for(var yy=3;yy<H;yy+=9) R(x-1,yy,2,4,"#132030");
  });
  hc.forEach(function(r){ var y=Math.round(r*TILE);
    R(0,y-6,W,12,"#0a111c"); R(0,y-6,W,1,"#0d1626"); R(0,y+5,W,1,"#060a11");
    for(var xx=3;xx<W;xx+=9) R(xx,y-1,4,2,"#132030");
  });
  // hazard chevrons at the four crossings
  vc.forEach(function(c){ hc.forEach(function(r){
    var x=Math.round(c*TILE), y=Math.round(r*TILE);
    R(x-3,y-2,2,1,"#3a3418"); R(x-1,y-1,2,1,"#3a3418"); R(x+1,y,2,1,"#3a3418");
  }); });
}

/* raised beveled platform */
function drawRoom(z,floorCol,accent,office){
  var x=z.c0*TILE, y=z.r0*TILE, w=(z.c1-z.c0+1)*TILE, h=(z.r1-z.r0+1)*TILE;
  // drop shadow
  p.globalAlpha=0.5; R(x+3,y+5,w,h,"#04070c"); p.globalAlpha=1;
  // platform base (front/side thickness)
  R(x,y+2,w,h,shade(floorCol,0.5));
  // top surface
  R(x,y,w,h-2,floorCol);
  // inner floor tiles (subtle)
  for(var cc=z.c0;cc<=z.c1;cc++) for(var rr=z.r0;rr<=z.r1-1;rr++){
    if((cc+rr)%2===0) R(cc*TILE,rr*TILE,TILE,TILE,shade(floorCol,1.035));
  }
  // bevel edges: lit top + left, dark bottom + right
  R(x,y,w,1,shade(floorCol,1.5));
  R(x,y,1,h-2,shade(floorCol,1.3));
  R(x,y+h-3,w,1,shade(floorCol,0.4));
  R(x+w-1,y,1,h-2,shade(floorCol,0.4));
  // back wall band with rim light
  var wallH=Math.round(TILE*1.6);
  R(x+1,y+1,w-2,wallH,shade(floorCol,0.72));
  R(x+1,y+1,w-2,1,shade(floorCol,1.7));           // rim light
  R(x+1,y+wallH+1,w-2,1,shade(floorCol,0.35));     // wall base shadow
  if(accent){
    R(x+1,y+wallH,w-2,1,accent);                   // vendor accent line under wall
    addLight((x+w/2),(y+h/2), Math.max(w,h)*0.62, accent, 0.09); // faint vendor tint
  }
  // baseline cool ambient so no room is a dark void
  addLight((x+w/2),(y+h*0.55), Math.max(w,h)*0.7, "#2f4a70", 0.12);
}

function drawRoomFor(b){
  var z=b.zone;
  var floor = shade(b.color,0.16);
  floor = mix(floor,"#141d2e",0.72);   // mostly neutral, hint of vendor
  drawRoom(z, floor, b.color, false);
}
function mix(a,bcol,t){ // a,bcol are rgb() or hex; return blended rgb string
  var ca=parseRGB(a), cb=parseRGB(bcol);
  return "rgb("+Math.round(ca[0]+(cb[0]-ca[0])*t)+","+Math.round(ca[1]+(cb[1]-ca[1])*t)+","+Math.round(ca[2]+(cb[2]-ca[2])*t)+")";
}
function parseRGB(s){
  if(s[0]==="#") return hex(s);
  var m=s.match(/(\d+),\s*(\d+),\s*(\d+)/); return [+m[1],+m[2],+m[3]];
}

/* interior: racks, cable tray, console, decals */
function drawRoomInterior(b){
  var z=b.zone;
  // cable tray along the back wall
  var trayY=(z.r0)*TILE + Math.round(TILE*1.6) + 1;
  R((z.c0+1)*TILE, trayY, (z.c1-z.c0-1)*TILE, 2, "#0c1524");
  // racks
  var n=b.repos.length;
  var span=(z.c1-z.c0+1);
  var startC=z.c0 + 2;
  var gapC=3;
  for(var i=0;i<n;i++){
    var rc=startC+i*gapC;
    var rx=rc*TILE, ry=(z.r0)*TILE + Math.round(TILE*1.6) + 3;
    var active=(b.repos[i]===b.repo) && (b.state==="building"||b.state==="reviewing") && b.alive;
    drawRack(rx,ry, active?STATE[b.state].c:null, b.phase*1.7+i, b.repos[i]);
  }
  // floor cable runs from the racks down toward the console
  var trayBase=(z.r0)*TILE+Math.round(TILE*1.6)+5;
  R((z.c0+3)*TILE, trayBase, 1, (z.r1-z.r0-3)*TILE, "#0b1420");
  R((z.c0+3)*TILE-1, trayBase, 1, (z.r1-z.r0-3)*TILE, rgba(b.color,0.18));
  // caution strip on the floor (front)
  var hzx=(z.c0+2)*TILE, hzy=(z.r1-2)*TILE+2;
  R(hzx,hzy,16,2,"#141d2b");
  for(var s2=0;s2<5;s2++) R(hzx+1+s2*3, hzy, 2,2, "#b8941f");
  // a couple of floor-standing crates for depth
  crate((z.c0+1)*TILE+2, (z.r1-4)*TILE, b.color);
  // pipes along the right wall
  R((z.c1-1)*TILE+3, (z.r0)*TILE+3, 1, (z.r1-z.r0-2)*TILE, "#243248");
  R((z.c1-1)*TILE+5, (z.r0)*TILE+3, 1, (z.r1-z.r0-2)*TILE, "#1a2740");
  // console desk with monitor (front-right)
  drawConsole((z.c1-4)*TILE, (z.r1-4)*TILE, b);
  // workbench at the work spot (robot builds/reviews here)
  var lit = b.alive && (b.state==="building"||b.state==="reviewing");
  drawBench(Math.round(b.home.x)-7, Math.round(b.home.y)-6, lit?STATE[b.state].c:null, b.color);
  // wall status lamp
  var lampCol = !b.alive?"#ff5c5c":(b.state==="idle"?"#3a7a55":STATE[b.state].c);
  R((z.c1-1)*TILE, (z.r0)*TILE+3, 2,2, lampCol);
  R((z.c1-1)*TILE, (z.r0)*TILE+3, 2,1, shade(lampCol,1.4));
  if(b.alive && b.state!=="idle") addLight((z.c1-1)*TILE+1,(z.r0)*TILE+4, 13, lampCol, 0.3);
}
function crate(x,y,col){
  R(x,y,7,6,"#141d2c"); R(x,y,7,1,"#26344c"); R(x,y,1,6,"#1e2c42"); R(x+6,y,1,6,"#0b1220"); R(x,y+5,7,1,"#0b1220");
  R(x+1,y+2,5,1,rgba(col,0.4)); R(x+2,y+1,1,4,"#0e1626"); R(x+4,y+1,1,4,"#0e1626");
}
function drawBench(x,y,glow,vc){
  R(x,y+3,14,4,"#131d2c"); R(x,y+3,14,1,"#28374f"); R(x,y+7,14,1,"#0a1119");
  R(x+1,y+7,1,2,"#0e1626"); R(x+12,y+7,1,2,"#0e1626");       // legs
  R(x+2,y,6,4, glow?rgba(glow,0.85):"#173254"); R(x+2,y,6,1, glow?shade(glow,1.3):"#20406a"); // slanted screen
  if(glow){ addLight(x+7,y+2,20,glow,0.32); }
  R(x+9,y+1,4,1,rgba(vc,0.45)); R(x+9,y+3,3,1,rgba(vc,0.3));  // keys/mat
}

function drawRack(x,y,glow,ph,repo){
  var w=16,h=Math.round(TILE*2.4);
  // cabinet
  R(x,y,w,h,"#0b1220");
  R(x,y,w,1,"#2c3d59"); R(x,y,1,h,"#1b2941"); R(x+w-1,y,1,h,"#070c15"); R(x,y+h-1,w,1,"#070c15");
  // rack units + blinking LEDs
  var units=6, uh=(h-4)/units;
  for(var u=0;u<units;u++){
    var uy=y+2+u*uh;
    R(x+2,uy,w-4,Math.max(1,uh-1),"#131f31");
    var on = ((Math.floor(ph*3)+u*2)%3)===0;
    var led = glow ? glow : (on?"#37b06a":"#22334c");
    R(x+w-4,uy,2,1,led);
    R(x+3,uy,1,1, on?"#3a5a80":"#1a2740");
  }
  // little top screen
  R(x+3,y+1,w-6,2, glow?rgba(glow,0.8):"#1c3a54");
  if(glow){
    p.globalAlpha=0.16; R(x-2,y-2,w+4,h+4,glow); p.globalAlpha=1;
    addLight(x+w/2, y+h, 30, glow, 0.55);
    if(!reduced && chance(0.22)) spawnSpark(x+w/2, y-1, glow, true);
  } else {
    addLight(x+w/2, y+h*0.7, 18, "#2ea36a", 0.16);   // faint idle server glow
  }
}

/* small console with glowing monitor */
function drawConsole(x,y,b){
  R(x,y+4,14,3,"#141d2c");          // desk
  R(x,y+4,14,1,"#22304a");
  R(x+8,y,7,5,"#0a1220");           // monitor bezel
  var scr = b.alive ? (b.state==="idle"?"#1d3a52":STATE[b.state].c) : "#3a2530";
  R(x+9,y+1,5,3, b.alive?rgba(scr,0.85):"#3a2530");
  // scrolling code lines on screen
  if(b.alive){
    var ph=Math.floor(b.phase*4);
    R(x+9,y+1+(ph%3),3,1, shade(scr,1.3));
    addLight(x+11,y+2, 18, scr, 0.45);
  }
  R(x+11,y+5,1,1,"#22304a");        // stand
}

/* ---------- ATRIUM (decorative ops-desk) ---------- */
function drawAtrium(){
  var z=ATRIUM;
  drawRoom(z, "#182335", "#3b4a66", false);
  var x=z.c0*TILE, y=z.r0*TILE, w=(z.c1-z.c0+1)*TILE, h=(z.r1-z.r0+1)*TILE;
  // fleet emblem decal on the floor
  var cx=x+w/2, cy=y+h*0.66;
  p.globalAlpha=0.5;
  ring(cx,cy,13,"#33456a"); ring(cx,cy,10,"#2b3a5a");
  R(cx-13,cy,26,1,"#2a3a58"); R(cx,cy-13,1,26,"#2a3a58");
  p.globalAlpha=1;
  // glowing fleet core rising from the emblem (the centerpiece)
  var pulse=0.5+0.5*Math.sin(p_phase()*2);
  R(cx-1,cy-18,2,18, rgba("#5cc8ff",0.45));
  for(var hr=0;hr<4;hr++){ var ry=cy-4-hr*4; ring(cx,ry, 3+hr, rgba("#69ccff",0.55-hr*0.1)); }
  R(cx-2,cy-2,4,3,"#0b1626"); R(cx-2,cy-2,4,1,"#2a4a68");   // pedestal
  addLight(cx,cy-8, 46, "#48b4ff", 0.22+0.14*pulse);
  // wall of ops screens
  var bx=x+4, by=y+Math.round(TILE*1.6)+3;
  for(var s=0;s<5;s++){
    var sx=bx+s*7;
    R(sx,by,6,6,"#0a1220"); R(sx,by,6,1,"#1c2a40");
    var col=["#5cb4ff","#f7bd4e","#5fce9b","#c98bff","#ff8fb3"][s];
    R(sx+1,by+1,4,4, rgba(col,0.6));
    if(!reduced){ R(sx+1,by+1+(Math.floor(p_phase()*3+s)%3),3,1,shade(col,1.3)); R(sx+1,by+4,2,1,rgba(col,0.9)); }
  }
  addLight(bx+16,by+3, 40, "#5cb4ff", 0.22);
  // operator desk under the screens
  R(bx-1,by+9,36,3,"#182234"); R(bx-1,by+9,36,1,"#28374f"); R(bx-1,by+12,36,1,"#0b1220");
  R(bx+15,by+11,2,2,"#141d2c"); // chair back nub
  // coffee mug + keyboard
  R(bx+2,by+8,4,1,"#20304a"); R(bx+30,by+7,2,2,"#7d5a44"); R(bx+30,by+6,2,1,"#9c7358");
  // plants + a bench
  plant(x+w-7, y+h-7); plant(x+6, y+h-6);
  R(x+w/2-6,y+h-5,12,2,"#182234"); R(x+w/2-6,y+h-5,12,1,"#26344c");
}
function ring(cx,cy,r,col){
  for(var a=0;a<Math.PI*2;a+=0.5){ R(Math.round(cx+Math.cos(a)*r),Math.round(cy+Math.sin(a)*r),1,1,col); }
}
function plant(x,y){
  R(x,y+2,3,3,"#5a4636");          // pot
  R(x,y+2,3,1,"#6e5744");
  R(x+1,y-1,1,3,"#2f7d4a"); R(x,y,1,2,"#3a9159"); R(x+2,y,1,2,"#2f7d4a"); // leaves
}
var _pph=0; function p_phase(){ return _pph; }

/* ---------- OFFICE interior ---------- */
var boardCols=["needs-triage","claimed","blocked","ready"];
var boardColColor={ "needs-triage":"#f7bd4e","claimed":"#5cb4ff","blocked":"#ff5c5c","ready":"#5fce9b" };
var stickies=[]; (function(){ for(var i=0;i<9;i++) stickies.push({col:pick(boardCols),row:ri(0,3)}); })();
function drawOfficeInterior(){
  var z=OFFICE;
  var x=z.c0*TILE, y=z.r0*TILE, w=(z.c1-z.c0+1)*TILE, h=(z.r1-z.r0+1)*TILE;
  // whiteboard mounted on back wall
  var bx=x+3, by=y+2, bw=w-6, bh=Math.round(TILE*3.0);
  R(bx-1,by-1,bw+2,bh+2,"#070c15");
  R(bx,by,bw,bh,"#e9edf4");
  R(bx,by,bw,1,"#ffffff"); R(bx,by+bh-1,bw,1,"#aab4c4");
  var cw=bw/4;
  for(var c=0;c<4;c++){
    var ccx=bx+c*cw;
    if(c>0) R(ccx,by,1,bh,"#c3ccd8");
    R(ccx+2,by+2,cw-5,1,boardColColor[boardCols[c]]);
    // column header label ticks
    R(ccx+2,by+2,2,1,shade(boardColColor[boardCols[c]],0.7));
  }
  stickies.forEach(function(s,i){
    var ci=boardCols.indexOf(s.col); if(ci<0)ci=0;
    var sx=bx+ci*cw+3+(i%2)*5, sy=by+5+s.row*4;
    R(sx,sy,4,3,boardColColor[s.col]); R(sx,sy,4,1,shade(boardColColor[s.col],1.3));
  });
  addLight(x+w/2, by+bh/2, w*0.7, "#eaf0ff", 0.16); // board glow
  // central holo-table projecting the triage board (office centerpiece)
  var htx=x+w/2, hty=y+h*0.6;
  p.globalAlpha=0.4; R(htx-20,hty-4,40,11,"#1b2740"); R(htx-20,hty-4,40,1,"#24324c"); p.globalAlpha=1; // rug
  R(htx-15,hty,30,4,"#1c2740"); R(htx-15,hty,30,1,"#334564"); R(htx-15,hty+4,30,1,"#0b1220"); // table
  var hpulse=0.6+0.4*Math.sin(p_phase()*2.5);
  for(var c2=0;c2<4;c2++){ var hc=boardColColor[boardCols[c2]];
    var bx2=htx-13+c2*7;
    R(bx2, hty-3-(c2%2)-Math.round(hpulse), 5,3, rgba(hc,0.7)); R(bx2, hty-3-(c2%2)-Math.round(hpulse), 5,1, rgba(hc,0.95));
  }
  addLight(htx,hty-2, 40, "#7fd0ff", 0.16+0.09*hpulse);
  // chairs around the table
  R(htx-13,hty-3,3,2,"#141d2c"); R(htx+2,hty-3,3,2,"#141d2c"); R(htx+10,hty-3,3,2,"#141d2c");
  R(htx-13,hty+5,3,2,"#141d2c"); R(htx+2,hty+5,3,2,"#141d2c"); R(htx+10,hty+5,3,2,"#141d2c");
  // side filing cabinet + water cooler + plant, to fill the floor
  var cbx=x+4, cby=y+h-9;
  R(cbx,cby,6,7,"#182234"); R(cbx,cby,6,1,"#28374f"); R(cbx+1,cby+2,4,1,"#0c1626"); R(cbx+1,cby+4,4,1,"#0c1626");
  R(x+w-8,y+h-9,4,7,"#16202f"); R(x+w-7,y+h-11,2,3,rgba("#5cb4ff",0.6));   // cooler
  plant(x+w-6, y+h-6);
  addLight(x+w-6,y+h-9, 16, "#5cb4ff", 0.18);
  // OFFICE label handled by DOM
}

/* ---------- effects ---------- */
function drawScan(b){
  var z=b.zone, i=b.repos.indexOf(b.repo); if(i<0)i=0;
  var rx=(z.c0+2+i*3)*TILE, ry=(z.r0)*TILE+Math.round(TILE*1.6)+3;
  var yy=ry + ((Math.sin(b.phase*2)+1)/2)*(TILE*2.2);
  p.globalAlpha=0.55; R(rx,Math.round(yy),16,1,"#9cccff"); p.globalAlpha=1;
}
function drawSparks(){
  sparks.forEach(function(s){ p.globalAlpha=clamp(s.life,0,1); R(Math.round(s.x),Math.round(s.y),1,1,s.col); });
  p.globalAlpha=1;
}
function drawPackets(){
  packets.forEach(function(k){ R(Math.round(k.x),Math.round(k.y),2,1,k.c); });
}
function ringAt(x,y,col){
  R(x-9,y-10,18,1,col); R(x-9,y+9,18,1,col); R(x-10,y-9,1,18,col); R(x+9,y-9,1,18,col);
}

/* ============================================================
   ROBOT sprite (bigger, shaded, per-vendor silhouette)
   feet centre at (b.x,b.y)
   ============================================================ */
function drawRobot(b){
  var x=Math.round(b.x), y=Math.round(b.y);
  var pr=b.profile;
  var moving = Math.abs(b.x-b.tx)>0.6 || Math.abs(b.y-b.ty)>0.6;
  var walkP = b.phase*11;
  var bob = reduced?0:(moving? Math.round(Math.abs(Math.sin(walkP))*2) : Math.round(Math.sin(b.phase*2)*0.8));
  var st = STATE[b.state];
  var body = b.alive ? b.color : "#525c6e";
  var bodyD = shade(body,0.6), bodyL = shade(body,1.16), head = shade(body,1.22);
  var light = b.alive ? st.c : "#ff5c5c";

  // soft shadow (always on the floor plane)
  p.globalAlpha=0.32; ellip(x,y+1,7,2,"#04070c"); p.globalAlpha=1;
  if(!b.alive){ drawDead(b,x,y); return; }

  var top = y - (18 + pr.tall) - bob;   // head-ish top
  var fy = y - bob;                      // feet baseline w/ bob

  // legs (walk cycle)
  var swing = moving && !reduced ? Math.sin(walkP) : 0;
  R(x-3, fy-4+ (swing>0?-1:0), 2,4, bodyD);
  R(x+1, fy-4+ (swing<0?-1:0), 2,4, bodyD);
  R(x-3, fy-1, 2,1, shade(body,0.45)); R(x+1, fy-1, 2,1, shade(body,0.45));

  // body
  R(x-4, fy-13-pr.tall, 8, 9+pr.tall, body);
  R(x-4, fy-13-pr.tall, 8, 1, bodyL);         // top light
  R(x-4, fy-13-pr.tall, 1, 9+pr.tall, bodyL); // left light
  R(x+3, fy-13-pr.tall, 1, 9+pr.tall, bodyD); // right shade
  R(x-4, fy-5, 8,1, bodyD);
  // chest core (state light) with pulse
  var pulse = reduced?1:(0.6+0.4*Math.sin(b.phase*4));
  R(x-1, fy-11-pr.tall, 2,2, light);
  p.globalAlpha=0.5*pulse; R(x-2,fy-12-pr.tall,4,4,light); p.globalAlpha=1;

  // arms + tool
  var armSwing = moving && !reduced ? Math.round(Math.sin(walkP)*2) : 0;
  var work = (b.state==="building"||b.state==="reviewing"||b.state==="triaging");
  var toolArm = work && !reduced ? Math.round(Math.sin(b.phase*12)*2) : 0;
  R(x-6, fy-12-pr.tall+ (moving?armSwing:0), 2,5, bodyD);      // left arm
  R(x+4, fy-12-pr.tall+ (work? toolArm : -armSwing), 2,5, bodyD); // right arm
  drawTool(b,x,fy-pr.tall,toolArm,light);

  // head
  var hy = fy-13-pr.tall-6;
  if(pr.head==="square"){ R(x-3,hy,6,6,head); R(x-3,hy,6,1,shade(body,1.4)); }
  else { R(x-3,hy+1,6,5,head); R(x-2,hy,4,1,head); R(x-3,hy+1,6,1,shade(body,1.4)); }
  R(x-3,hy+1,1,5,bodyL); R(x+2,hy+1,1,5,bodyD);
  // ears (kimi)
  if(pr.ears===2){ R(x-3,hy-1,1,2,head); R(x+2,hy-1,1,2,head); }
  // visor / eyes
  if(pr.eyes==="visor"){ R(x-2,hy+2,4,2,"#0b1119"); R(x-2,hy+2,4,1, b.blink>0?"#0b1119":light); }
  else if(pr.eyes==="cyclops"){ R(x-2,hy+2,4,2,"#0b1119"); if(b.blink<=0) R(x-1,hy+2,2,1,light); }
  else { R(x-2,hy+2,4,2,"#0b1119"); if(b.blink<=0){ R(x-2,hy+2,1,1,light); R(x+1,hy+2,1,1,light);} }
  // antenna
  if(pr.antenna==="ball"){ R(x,hy-2,1,2,shade(body,0.7)); var bl=reduced?1:(Math.sin(b.phase*6)>-0.3?1:0.35); p.globalAlpha=bl; R(x-1,hy-3,2,2,light); p.globalAlpha=1; }
  else if(pr.antenna==="rod"){ R(x,hy-3,1,3,shade(body,0.7)); R(x,hy-3,1,1,light); }

  // ping over head when a prompt is picked up
  if(b.flash>0){ p.globalAlpha=b.flash; R(x-1,top-3,2,3,"#8fe0ff"); R(x-2,top-1,4,1,"#8fe0ff"); p.globalAlpha=1; addLight(x,top,20,"#8fe0ff",b.flash*0.8); }

  // robot core casts light
  addLight(x, fy-10, 26, light, b.state==="idle"?0.18:0.4);
}
function drawTool(b,x,fy,toolArm,light){
  var hx=x+6, hy=fy-10+toolArm;
  if(b.state==="building"){
    R(hx,hy,1,4,"#8a97ab"); R(hx-1,hy-1,3,2,"#c9d5e6");     // hammer
  } else if(b.state==="reviewing"){
    R(hx,hy,3,3,"#0b1119"); R(hx,hy,3,1,light); R(hx,hy+2,3,1,light); R(hx,hy,1,3,light); R(hx+2,hy,1,3,light); R(hx+3,hy+3,2,2,"#8a97ab"); // magnifier
  } else if(b.state==="triaging"){
    R(hx,hy-1,4,5,"#e9edf4"); R(hx+1,hy,2,1,"#8894a8"); R(hx+1,hy+2,2,1,"#8894a8"); // clipboard
  }
}
function drawDead(b,x,y){
  var flick = (!reduced && Math.floor(b.phase*20)%5===0) ? 1 : 0;
  // toppled robot on its side
  R(x-6,y-6,12,5,"#464f61");
  R(x-6,y-6,12,1,"#59637a");
  R(x+4,y-9,6,6,"#3f4757");                 // head fallen to the right
  // X eyes
  R(x+5,y-8,1,1,"#ff5c5c"); R(x+8,y-8,1,1,"#ff5c5c"); R(x+6,y-7,1,1,"#ff5c5c"); R(x+7,y-7,1,1,"#ff5c5c"); R(x+5,y-6,1,1,"#ff5c5c"); R(x+8,y-6,1,1,"#ff5c5c");
  // sputtering alert
  if(flick){ R(x-1,y-13,2,4,"#ff7a7a"); R(x-1,y-8,2,1,"#ff7a7a"); spawnSpark(x,y-6,"#ff5c5c",true); }
  addLight(x,y-4, 26, "#ff3b3b", 0.28+ (flick?0.25:0));
}
function ellip(cx,cy,rx,ry,col){
  for(var yy=-ry;yy<=ry;yy++){ var ww=Math.round(rx*Math.sqrt(1-(yy*yy)/(ry*ry))); R(cx-ww,cy+yy,ww*2,1,col); }
}

/* ============================================================
   ATMOSPHERE PASS  (full-res, over the crisp blit)
   ============================================================ */
function drawAtmosphere(){
  // additive glows
  vctx.save();
  vctx.globalCompositeOperation="lighter";
  lights.forEach(function(L){
    var s=artToScreen(L.x,L.y); var r=L.r*scale;
    var g=vctx.createRadialGradient(s.x,s.y,0,s.x,s.y,r);
    g.addColorStop(0, rgba2(L.c,0.55*L.i)); g.addColorStop(0.5, rgba2(L.c,0.16*L.i)); g.addColorStop(1,"rgba(0,0,0,0)");
    vctx.fillStyle=g; vctx.beginPath(); vctx.arc(s.x,s.y,r,0,7); vctx.fill();
  });
  // dust motes in light
  dust.forEach(function(d){
    var px=d.x*vw, py=d.y*vh;
    vctx.fillStyle="rgba(150,180,220,"+(0.05+0.1*d.z)+")";
    vctx.fillRect(px,py, d.z<0.6?1:1.5, d.z<0.6?1:1.5);
  });
  vctx.restore();

  // vignette
  var vg=vctx.createRadialGradient(vw/2,vh/2, Math.min(vw,vh)*0.35, vw/2,vh/2, Math.max(vw,vh)*0.72);
  vg.addColorStop(0,"rgba(0,0,0,0)"); vg.addColorStop(1,"rgba(3,6,12,0.72)");
  vctx.fillStyle=vg; vctx.fillRect(0,0,vw,vh);

  // scanlines
  if(scanPat){ vctx.fillStyle=scanPat; vctx.globalAlpha=0.5; vctx.fillRect(0,0,vw,vh); vctx.globalAlpha=1; }
}
function rgba2(col,a){ var c=parseRGB(col); return "rgba("+c[0]+","+c[1]+","+c[2]+","+a+")"; }
var scanPat=null;
function buildScanPattern(){
  var c=document.createElement("canvas"); c.width=1; c.height=3; var cx=c.getContext("2d");
  cx.fillStyle="rgba(0,0,0,0.5)"; cx.fillRect(0,2,1,1);
  scanPat=vctx.createPattern(c,"repeat");
}

/* ============================================================
   SIM ENGINE (unchanged behaviour)
   ============================================================ */
var TICK_MS=2600, tickCount=0;
function outcomeFor(kind){
  if(kind==="build")  return pick(["opened PR","pushed fixups","needs-human","resumed"]);
  if(kind==="review") return pick(["approved","changes-requested","commented","re-request → approved"]);
  if(kind==="triage") return pick(["labeled ready","routed to builder","marked blocked","ruling posted"]);
  return "ok";
}
function startSession(b,forceKind){
  var kind=forceKind||STATE[b.state].kind;
  b.repo=pick(b.repos);
  b.lastKey=(kind==="triage")?"board":issueKey(b.repo);
  logLine(b,"k-"+(kind==="build"?"build":kind==="review"?"review":"triage"),
    "SESSION START kind="+kind+" key="+b.lastKey+" timeout="+(kind==="build"?1200:600)+"s");
  b.sessions.unshift({t:nowClock(),txt:"START "+kind+" "+b.lastKey,cls:""}); b.sessions=b.sessions.slice(0,6);
}
function endSession(b){
  var kind=STATE[b.state].kind; if(kind==="idle"||kind==="dead") return;
  var rc=chance(0.12)?1:0, dur=ri(18,140), out=rc?"aborted (budget)":outcomeFor(kind);
  b.lastEndTxt="rc="+rc+" · "+out;
  logLine(b,"k-"+(kind==="build"?"build":kind==="review"?"review":"triage"),
    "SESSION END kind="+kind+" rc="+rc+" dur="+dur+"s outcome="+out, rc?"cr":"ok");
  b.sessions.unshift({t:nowClock(),txt:"END "+kind+" "+out,cls:rc?"warn":"ok"}); b.sessions=b.sessions.slice(0,6);
}
function setState(b,st){
  if(b.state===st) return;
  if(b.state==="building"||b.state==="reviewing"||b.state==="triaging") endSession(b);
  if(b.triSlot!=null && st!=="triaging") b.triSlot=null;
  b.state=st;
  if(st==="triaging"){ b.triSlot=freeTriSlot(); var sl=triSlots[b.triSlot]; b.tx=sl.x; b.ty=sl.y; startSession(b); }
  else if(st==="building"||st==="reviewing"){ b.tx=b.home.x; b.ty=b.home.y; startSession(b); }
  else if(st==="idle"){ wander(b); }
}
function wander(b){ var z=b.zone; b.tx=(ri(z.c0+2,z.c1-2)+0.5)*TILE; b.ty=(ri(z.r0+5,z.r1-1)+0.5)*TILE; }
function tick(){
  tickCount++;
  boxes.forEach(function(b){
    if(!b.alive){
      if(chance(0.22)){ b.alive=true; b.bootAt=Date.now(); b.deadT=0; b.state="idle"; wander(b); logLine(b,"k-boot","boot: gh ✓ box ✓ — on duty"); if(inspFor===b.id) refreshInspector(); }
      else if(tickCount%2===0) logLine(b,"k-dead","⚠ no evidence line — cron silent");
      return;
    }
    if(b.queue.length){
      var q=b.queue.shift(); q.picked=true; q.pickedAt=nowClock(); b.flash=1; b.picked.push(q);
      logLine(b,"k-prompt","📨 operator prompt picked up → kind="+(b.role==="triage"?"triage":b.role==="builder"?"build":"review"));
      setState(b, b.role==="triage"?"triaging":b.role==="builder"?"building":"reviewing"); b.timer=ri(2,4);
      if(inspFor===b.id){ renderQueue(b); refreshInspector(); }
      return;
    }
    if(chance(0.02)){ endSession(b); b.alive=false; b.state="dead"; logLine(b,"k-dead","⚠ tick boundary missed — box unreachable"); if(inspFor===b.id) refreshInspector(); return; }
    b.timer--;
    if(b.timer>0){ if(b.state==="idle" && chance(0.5)) wander(b); return; }
    var r=Math.random(), next;
    if(b.role==="triage")       next=r<0.62?"triaging":"idle";
    else if(b.role==="builder") next=r<0.5?"building": r<0.68?"triaging":"idle";
    else                        next=r<0.5?"reviewing":r<0.68?"triaging":"idle";
    setState(b,next); b.timer=next==="idle"?ri(1,3):ri(2,5);
  });
  updateRoster(); if(inspOpen) refreshInspector();
}

/* ============================================================
   MAIN LOOP
   ============================================================ */
var lastT=0;
function frame(t){
  var dt=Math.min(0.05,(t-lastT)/1000)||0.016; lastT=t; _pph+=dt;
  boxes.forEach(function(b){
    b.phase+=dt;
    if(b.flash>0) b.flash=Math.max(0,b.flash-dt*1.4);
    if(b.blink>0) b.blink-=dt; else if(!reduced && chance(0.004)) b.blink=0.12;
    if(!b.alive){ b.deadT+=dt; return; }
    var dx=b.tx-b.x, dy=b.ty-b.y, d=Math.hypot(dx,dy);
    if(d>0.6){ var sp=(reduced?70:30)*dt, m=Math.min(sp,d); b.x+=dx/d*m; b.y+=dy/d*m; b.face=dx<0?-1:1; }
    else { b.x=b.tx; b.y=b.ty; }
    if(!reduced){
      if(b.state==="building" && chance(0.5)) spawnSpark(b.x+6,b.y-8,"#ffcf5a",true);
      if(b.state==="reviewing" && chance(0.1)) spawnSpark(b.x+7,b.y-8,"#9cccff",true);
    }
  });
  stepSparks(dt); stepPackets(dt); stepDust(dt);
  drawWorld();
  blit();
  drawAtmosphere();
  requestAnimationFrame(frame);
}
function stepDust(dt){
  dust.forEach(function(d){ d.y-=d.vy*dt*60/60; d.x+=d.vx; if(d.y<0){d.y=1;d.x=Math.random();} if(d.x<0)d.x=1; if(d.x>1)d.x=0; });
}
/* seed & animate data packets along each room's cable tray */
function stepPackets(dt){
  if(packets.length<boxes.length*2 && chance(0.06)){
    var b=pick(boxes); if(b.alive){
      var z=b.zone, trayY=(z.r0)*TILE+Math.round(TILE*1.6);
      packets.push({x:(z.c0+1)*TILE, y:trayY, vx:rnd(10,22), max:(z.c1-1)*TILE, c:rgba(b.color,0.9)});
    }
  }
  for(var i=packets.length-1;i>=0;i--){ var k=packets[i]; k.x+=k.vx*dt; if(k.x>k.max) packets.splice(i,1); }
}

/* ---------- blit ---------- */
var view=document.getElementById("view"), vctx=view.getContext("2d");
var vw=0,vh=0,scale=1,ox=0,oy=0,dpr=1;
function resize(){
  var host=document.getElementById("floor"); var r=host.getBoundingClientRect();
  dpr=Math.min(2,window.devicePixelRatio||1);
  vw=r.width; vh=r.height;
  view.width=Math.floor(vw*dpr); view.height=Math.floor(vh*dpr);
  scale=Math.max(1,Math.min(vw/W, vh/H));
  ox=Math.round((vw-W*scale)/2); oy=Math.round((vh-H*scale)/2);
  vctx.setTransform(dpr,0,0,dpr,0,0); vctx.imageSmoothingEnabled=false;
  buildScanPattern(); layoutLabels();
}
function blit(){
  vctx.fillStyle="#05080e"; vctx.fillRect(0,0,vw,vh);
  vctx.imageSmoothingEnabled=false;
  vctx.drawImage(buf,0,0,W,H, ox,oy, W*scale, H*scale);
}
function artToScreen(ax,ay){ return {x:ox+ax*scale, y:oy+ay*scale}; }
function screenToArt(sx,sy){ return {x:(sx-ox)/scale, y:(sy-oy)/scale}; }

/* ---------- DOM zone labels ---------- */
var labelEls={};
function buildLabels(){
  var floor=document.getElementById("floor");
  makeLabel("__office","<b>Office</b> <span class='rl'>· triage board</span>", OFFICE, true);
  makeLabel("__atrium","<b>Operations</b> <span class='rl'>· fleet desk</span>", ATRIUM, true);
  boxes.forEach(function(b){ makeLabel(b.id,"<b>"+b.id+"</b> <span class='rl'>· "+b.role+"</span>", b.zone, false); });
  function makeLabel(id,html,z,top){ var el=document.createElement("div"); el.className="zlabel"; el.innerHTML=html; el.dataset.top=top?"1":""; floor.appendChild(el); labelEls[id]={el:el,z:z}; }
}
function layoutLabels(){
  for(var id in labelEls){ var L=labelEls[id];
    var atTop = L.el.dataset.top==="1";
    var pt=artToScreen(L.z.c0*TILE+3, atTop?(L.z.r0*TILE+ Math.round(TILE*1.6)+5):(L.z.r1*TILE-12));
    L.el.style.left=pt.x+"px"; L.el.style.top=pt.y+"px";
  }
}

/* ============================================================
   HUD (roster, ticker, tooltip, inspector) — unchanged logic
   ============================================================ */
var rosterEl=document.getElementById("roster");
function buildRoster(){
  boxes.forEach(function(b){
    var row=document.createElement("div"); row.className="rrow"; row.dataset.id=b.id;
    row.innerHTML="<span class='av' style='background:"+b.color+"'></span>"+
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
    var chip=row.querySelector(".chip"), st=STATE[b.state];
    chip.textContent=st.label; chip.style.color=st.c; chip.style.background=shade(st.c,0.16); chip.style.borderColor=shade(st.c,0.4);
    row.classList.toggle("sel", inspFor===b.id);
  });
}
var logEl=document.getElementById("log");
function logLine(b,cls,msg,extra){
  var l=document.createElement("div"); l.className="l "+cls; var m=msg;
  if(extra==="ok") m=msg.replace(/outcome=([^\s]+.*)$/,"outcome=<span class='ok'>$1</span>");
  if(extra==="cr") m=msg.replace(/rc=1/,"<span class='cr'>rc=1</span>");
  l.innerHTML="<span class='t'>"+nowClock()+"</span><span class='b'>"+b.id+"</span><span class='m'>"+m+"</span>";
  logEl.appendChild(l); while(logEl.childNodes.length>80) logEl.removeChild(logEl.firstChild); logEl.scrollTop=logEl.scrollHeight;
}
var tip=document.getElementById("tip");
function showTip(b,sx,sy){
  tip.querySelector(".t1").textContent=b.id;
  tip.querySelector(".t2").textContent=b.alive?(STATE[b.state].label+" · "+b.repo):"Disconnected · cron silent";
  tip.style.left=sx+"px"; tip.style.top=sy+"px"; tip.style.opacity="1";
}
function hideTip(){ tip.style.opacity="0"; }

var inspEl=document.getElementById("inspector"), inspOpen=false, inspFor=null;
function openInspector(id){ inspFor=id; inspOpen=true; inspEl.classList.add("open"); refreshInspector(); updateRoster(); }
function closeInspector(){ inspOpen=false; inspFor=null; inspEl.classList.remove("open"); updateRoster(); }
function fmtUptime(ms){ if(ms<0)ms=0; var s=Math.floor(ms/1000),h=Math.floor(s/3600),m=Math.floor((s%3600)/60),ss=s%60; return (h?h+"h ":"")+pad(m)+"m "+pad(ss)+"s"; }
function refreshInspector(){
  var b=byId[inspFor]; if(!b) return;
  document.getElementById("insp-id").textContent=b.id;
  document.getElementById("insp-meta").textContent=b.agent+" · "+b.role;
  document.getElementById("insp-badge").style.background=shade(b.color,0.22);
  drawAvatar(b);
  var st=STATE[b.state], vs=document.getElementById("v-status"); vs.textContent=st.label; vs.style.color=st.c;
  document.getElementById("v-uptime").textContent=b.alive?fmtUptime(Date.now()-b.bootAt):"—";
  document.getElementById("v-repo").textContent=b.alive?b.repo:"—";
  document.getElementById("v-tick").textContent=b.alive?"≤5m ago":"silent";
  var tl=document.getElementById("v-timeline"); tl.innerHTML="";
  if(!b.sessions.length) tl.innerHTML="<div class='ln'><span class='tk'>—</span>no sessions yet</div>";
  b.sessions.forEach(function(s){ var ln=document.createElement("div"); ln.className="ln"; ln.innerHTML="<span class='tk'>"+s.t+"</span><span class='"+(s.cls||"")+"'>"+s.txt+"</span>"; tl.appendChild(ln); });
  renderQueue(b);
}
function renderQueue(b){
  var q=document.getElementById("queue"); q.innerHTML="";
  b.queue.forEach(function(item){ q.appendChild(qEl(item,false)); });
  (b.picked||[]).slice(-2).forEach(function(item){ q.appendChild(qEl(item,true)); });
}
function qEl(item,picked){
  var d=document.createElement("div"); d.className="qitem"+(picked?" picked":"");
  d.innerHTML="<div class='qs'>"+(picked?"picked up "+item.pickedAt:"queued "+item.at+" · waiting for next tick")+"</div>"+escapeHtml(item.text);
  return d;
}
function escapeHtml(s){ return s.replace(/[&<>]/g,function(c){return c==="&"?"&amp;":c==="<"?"&lt;":"&gt;";}); }

var avEl=document.getElementById("insp-av"), avc=avEl.getContext("2d");
function drawAvatar(b){
  avc.imageSmoothingEnabled=false; avc.clearRect(0,0,34,34);
  var mini=document.createElement("canvas"); mini.width=17; mini.height=17; var mp=mini.getContext("2d");
  drawMiniRobot(mp,b); avc.drawImage(mini,0,0,17,17,0,0,34,34);
}
function drawMiniRobot(ctx,b){
  function r(x,y,w,h,c){ ctx.fillStyle=c; ctx.fillRect(x,y,w,h); }
  var x=8,y=16, body=b.alive?b.color:"#525c6e", light=b.alive?STATE[b.state].c:"#ff5c5c";
  r(x-3,y-4,2,4,shade(body,0.6)); r(x+1,y-4,2,4,shade(body,0.6));
  r(x-4,y-13,8,9,body); r(x-4,y-13,8,1,shade(body,1.2)); r(x-1,y-11,2,2,light);
  r(x-6,y-12,2,5,shade(body,0.6)); r(x+4,y-12,2,5,shade(body,0.6));
  var pr=b.profile;
  r(x-3,y-19,6,6,shade(body,1.22)); r(x-2,y-17,4,2,"#0b1119");
  if(pr.eyes==="cyclops") r(x-1,y-17,2,1,light); else { r(x-2,y-17,1,1,light); r(x+1,y-17,1,1,light); }
  if(pr.ears===2){ r(x-3,y-20,1,2,shade(body,1.22)); r(x+2,y-20,1,2,shade(body,1.22)); }
  if(pr.antenna==="ball"){ r(x,y-21,1,2,shade(body,0.7)); r(x-1,y-22,2,2,light); }
  else if(pr.antenna==="rod"){ r(x,y-22,1,3,shade(body,0.7)); r(x,y-22,1,1,light); }
}

/* ---------- interaction ---------- */
var hoverId=null;
function hitRobot(ax,ay){
  var best=null,bd=1e9;
  boxes.forEach(function(b){ var dx=ax-b.x, dy=ay-(b.y-10), d=dx*dx+dy*dy; if(d<bd && Math.abs(dx)<10 && dy>-18 && dy<12){ bd=d; best=b; } });
  return best;
}
view.addEventListener("mousemove",function(e){
  var r=view.getBoundingClientRect(), a=screenToArt(e.clientX-r.left,e.clientY-r.top), b=hitRobot(a.x,a.y);
  if(b){ hoverId=b.id; view.style.cursor="pointer"; var pt=artToScreen(b.x,b.y-20); showTip(b,pt.x,pt.y); }
  else { hoverId=null; hideTip(); view.style.cursor="default"; }
});
view.addEventListener("mouseleave",function(){ hoverId=null; hideTip(); });
view.addEventListener("dblclick",function(e){ var r=view.getBoundingClientRect(), a=screenToArt(e.clientX-r.left,e.clientY-r.top), b=hitRobot(a.x,a.y); if(b) openInspector(b.id); });
function focusBox(id){ var b=byId[id]; if(!b) return; openInspector(id); b.flash=1; }

document.getElementById("insp-close").addEventListener("click",closeInspector);
document.getElementById("prompt-send").addEventListener("click",sendPrompt);
document.getElementById("prompt-in").addEventListener("keydown",function(e){ if((e.metaKey||e.ctrlKey)&&e.key==="Enter") sendPrompt(); });
function sendPrompt(){
  var b=byId[inspFor]; if(!b) return; var ta=document.getElementById("prompt-in"), txt=ta.value.trim(); if(!txt) return;
  if(!b.alive){ var q=document.getElementById("queue"); var w=document.createElement("div"); w.className="qitem"; w.style.borderLeftColor="var(--dead)"; w.innerHTML="<div class='qs' style='color:var(--dead)'>undeliverable</div>Box is disconnected — no tick to drain the channel. Message not queued."; q.prepend(w); return; }
  b.queue.push({text:txt, at:nowClock(), picked:false}); ta.value=""; renderQueue(b);
}
var aboutBg=document.getElementById("about-bg");
document.getElementById("about-btn").addEventListener("click",function(){ aboutBg.classList.add("open"); });
document.getElementById("about-close").addEventListener("click",function(){ aboutBg.classList.remove("open"); });
aboutBg.addEventListener("click",function(e){ if(e.target===aboutBg) aboutBg.classList.remove("open"); });
document.addEventListener("keydown",function(e){ if(e.key==="Escape"){ aboutBg.classList.remove("open"); if(inspOpen) closeInspector(); } });
function tickClock(){ document.getElementById("clock").textContent=nowClock(); }

/* ---------- boot ---------- */
function init(){
  buildLabels(); buildRoster();
  window.addEventListener("resize",resize); resize();
  boxes.forEach(function(b,i){
    if(i%3===0){ var st=b.role==="builder"?"building":b.role==="reviewer"?"reviewing":"triaging"; b.state=st;
      if(st==="triaging"){ b.triSlot=freeTriSlot(); b.tx=triSlots[b.triSlot].x; b.ty=triSlots[b.triSlot].y; } else { b.tx=b.home.x; b.ty=b.home.y; }
      startSession(b); }
  });
  updateRoster(); tickClock(); setInterval(tickClock,1000); setInterval(tick,TICK_MS); requestAnimationFrame(frame);
}
init();
})();
