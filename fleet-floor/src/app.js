"use strict";
(function(){
var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
/* The page's own epoch, taken once at boot. Dev renders (FLOORDEV.renderMini)
   pin Date.now to this so a golden of a fixed (unit, state, size, t) does not
   drift with the wall clock between two draws — the REC timer and IDLE-24H
   read the clock, and demo session starts are derived from it at load. */
var BOOT=Date.now();
var DW=1280, DH=720, MODE="target", STATE="working", ROOM="builder", AGENT="claude";
/* BOX is the identity — the roster's box NAME, not a label derived from
   agent+role. Those coincide in the current fleet (claude-builder is both),
   which is exactly why deriving it survived this long: nothing in the roster
   format requires it, and when they diverge the console labels one box while
   its controls drive another. Set by drawCamCell (per tile) and focusUnit. */
var BOX="claude-builder";
function UNITID(u){return u.box||(u.agent+"-"+u.room);}
function UNIT(){return BOX;}
function ROLEWORD(){return ROOM;}
var lastHand={x:260,y:400};
/* The footprints the last-built robot reported, in robo-canvas space. The full
   room reads them straight off buildRobo's return; the grid cell renders on a
   different pass and needs them carried across, which is what this is. */
var lastFeet=null;
/* Where the last unit rendered actually IS, in ROOM coordinates: the point its
   hand works at, the top of its head, and each footprint. drawRobot is the one
   place that knows the sprite's scale and offset, so it is the one place that
   should be converting them — everything downstream that needs to put a mark
   on a unit reads these instead of guessing at the sprite's bounding box. */
var lastAnchors=null;

function oc(w,h){var c=document.createElement("canvas");c.width=w;c.height=h;return c;}
var scene=oc(DW,DH), S=scene.getContext("2d");
var glow =oc(DW,DH), G=glow.getContext("2d");
var comp =oc(DW,DH), C=comp.getContext("2d");
var tintR=oc(DW,DH), tintG=oc(DW,DH), tintB=oc(DW,DH);
var RW=520,RH=600;
var robo=oc(RW,RH), RB=robo.getContext("2d");
var remit=oc(RW,RH), RE=remit.getContext("2d");
var rrim=oc(RW,RH), RR=rrim.getContext("2d");
/* Portrait supersampling (#226 RC3). Every conference-cell portrait crops
   this same 520x600 sprite with a per-vendor width and stretches it to the
   same tile buffer, so a narrow crop (grok, 206px) lands ~40% fewer source
   pixels per screen pixel than a wide one (kimi, 330px) — four vendors, four
   effective resolutions. Portrait builds therefore run on their own trio,
   drawn at SS = clamp(pw/cropW, 1, SS_MAX): every builder already takes its
   canvas transform from its entry reset, so composing SS there (and in
   kimi's F transform, buildRim's pixel offsets and the key-light tint)
   scales the whole build with ZERO changes to the art. The room path keeps
   SS=1 and the original trio. Allocated once, lazily, at SS_MAX size
   (~25MB); per-build SS varies via the transform, and entry resets clear
   the full physical canvas so a smaller build never composites a larger
   build's stale margin. */
var SS=1, SS_MAX=2.6;
var roboP=null,RBP=null,remitP=null,REP=null,rrimP=null,RRP=null;
function ensurePortraitTrio(){
  if(roboP)return;
  var W2=Math.ceil(RW*SS_MAX),H2=Math.ceil(RH*SS_MAX);
  roboP=oc(W2,H2);RBP=roboP.getContext("2d");
  remitP=oc(W2,H2);REP=remitP.getContext("2d");
  rrimP=oc(W2,H2);RRP=rrimP.getContext("2d");
}
var noise=makeNoise(220);

function rgba(r,g,b,a){return "rgba("+r+","+g+","+b+","+a+")";}
function rr(c,x,y,w,h,r){c.beginPath();if(c.roundRect){c.roundRect(x,y,w,h,r);}else{c.moveTo(x+r,y);c.arcTo(x+w,y,x+w,y+h,r);c.arcTo(x+w,y+h,x,y+h,r);c.arcTo(x,y+h,x,y,r);c.arcTo(x,y,x+w,y,r);c.closePath();}}
function poly(c,pts){c.beginPath();for(var i=0;i<pts.length;i++){if(i)c.lineTo(pts[i][0],pts[i][1]);else c.moveTo(pts[i][0],pts[i][1]);}c.closePath();}
function plate(c,pts,top,bot,ed){var y0=1e9,y1=-1e9;for(var i=0;i<pts.length;i++){if(pts[i][1]<y0)y0=pts[i][1];if(pts[i][1]>y1)y1=pts[i][1];}var gg=c.createLinearGradient(0,y0,0,y1);gg.addColorStop(0,top);gg.addColorStop(1,bot);poly(c,pts);c.fillStyle=gg;c.fill();if(ed){c.strokeStyle=ed;c.lineWidth=1.2;c.lineJoin="round";c.stroke();}}
function pl(c,x0,y0,x1,y1,col,w){c.strokeStyle=col;c.lineWidth=w||1;c.beginPath();c.moveTo(x0,y0);c.lineTo(x1,y1);c.stroke();}
function rivet(c,x,y,col){c.fillStyle=col;c.beginPath();c.arc(x,y,1.5,0,7);c.fill();}
function makeNoise(n){var c=oc(n,n),x=c.getContext("2d"),d=x.createImageData(n,n),p=d.data;for(var i=0;i<p.length;i+=4){var v=Math.random()*255;p[i]=p[i+1]=p[i+2]=v;p[i+3]=255;}x.putImageData(d,0,0);return c;}
function fnoise(t){return Math.sin(t*11.3)*0.5+Math.sin(t*23.7+1.3)*0.3+Math.sin(t*57.1+0.7)*0.2;}
/* A phase angle derived from a string, so a per-unit animation can be offset
   by WHICH UNIT IT IS rather than by Math.random. Two boxes side by side then
   never blink in step, and the same box blinks the same way in two renders of
   the same commit — which is the property an asset map is made of. */
function strPhase(s){var h=2166136261;s=String(s);for(var i=0;i<s.length;i++){h^=s.charCodeAt(i);h=Math.imul(h,16777619);}return (h>>>0)/4294967296*6.283;}

var motes=[];for(var i=0;i<90;i++)motes.push({x:Math.random(),y:Math.random(),z:.3+Math.random()*.9,s:Math.random()*6.28});
var steam=[];for(var i=0;i<26;i++)steam.push({p:Math.random(),x:.72+Math.random()*.12,sway:Math.random()*6.28});
var floorHaze=[];for(var i=0;i<5;i++)floorHaze.push({x:Math.random(),sp:.006+Math.random()*.01,y:.80+i*.03,a:.05+Math.random()*.05});
var sparks=[];

var LAMPX=470,LAMPY=70,FLOORY=612,ROBOX=470,ROBOY=FLOORY;
var HOLOX=800,HOLOY=250,HOLOW=250,HOLOH=196;
/* The signage bay — a rectangle of back wall reserved for the room's name.
   The wall text was not an object. It was two fillText calls with no extent
   and no owner, so every prop bolted to the wall since has been placed as if
   that space were empty, and three of them ended up on top of it: the
   builder's conduit ran vertically through "SECTOR-7", and dispatch parked a
   radar dish over the S and a relay panel across the rest, burying the word
   "DISPATCH" completely. Individually each prop is fine. Together they read
   as three rooms nobody composed.
   Naming the rectangle is the structural half of the fix — a prop that lands
   here is now a visible mistake against a stated rule instead of a thing that
   looked free. Making the sign an opaque bolted plate is the other half: it
   has a silhouette, it occludes what passes behind it, and it can take the
   light the rest of the wall takes. */
var SIGN={x:676,y:182,w:308,h:88};
var WALL={x:250,y:150,w:760};
/* The rest of the wall, as named bays.
   Loop 11 reserved one rectangle and that was enough to stop props landing on
   the room's name — but it left every OTHER placement still being decided by
   eye, one prop at a time, which is the habit that put them there in the first
   place. So before anything new goes up, the whole wall gets stated: what is
   free, and what each free area is bounded by.
   Two constraints do most of the work. The unit stands at ROBOX=470 and is
   about 220 wide, so the centre column is not wall you can hang anything on —
   it is wall you look at the robot against, and the lamp cone runs down it.
   And each room already has floor-standing furniture backed up against the
   wall, so a bay has to stop where that starts.
                      x    y    w    h     bounded below by
   builder  left    250  188  126  216     the fab bay (y=430)
            right   726  404  270  148     the deck
   reviewer left    262  336  164  170     the inspection desk (x=372)
            right   690  428  300  124     the deck
   triage   left    262  330  160  196     the map console (x=372)
            right   836  424  160  128     the deck
   Every one of these was verified empty against the loop 12 renders, and each
   is quoted in the prop that fills it. If a later prop wants one of them, it
   has to say which. */
var BAYS={
  builder :{L:[250,188,126,216], R:[726,404,270,148]},
  reviewer:{L:[262,336,164,170], R:[690,428,300,124]},
  triage  :{L:[262,330,160,196], R:[836,424,160,128]}
};
/* And the rest of it, because seven rectangles out of a room is not a layout.
   Loop 11 named the sign's rectangle, loop 13 named six wall bays, and its own
   note says what was left: "every other placement still being decided by eye,
   one prop at a time" — which is the habit that put a conduit through SECTOR-7
   in the first place, still running, just further down the wall. Naming six
   free areas does not fix it while the deck, the keep-clear column and the
   fixed structure stay unstated, because a prop is placed against what is
   ALREADY THERE at least as often as against what is free.

   So: what the deck already carries, room by room, and what nothing may be
   placed on in any room. Numbers are read off the props themselves, not
   estimated — each row is the extent the function actually draws, and
   FLOORDEV.guides draws these over a rendered tile so the claim is checkable
   by looking rather than by trusting this comment.

   Declaring it found one collision immediately, which is the argument for
   declaring it: the builder's workbench ends at x=576 and its conveyor began
   at x=566, so ten pixels of belt ran through the bench top. Both are dark and
   the overlap is four pixels tall, which is exactly why eyes had not caught it
   in fifteen loops. The conveyor now starts at 580. */
var LAYOUT={
  /* Where a unit can be. Not a guess: the union of FLOORDEV.unitBox over all
     36 agent x room x state combinations, which is the alpha extent of the
     sprite the renderer actually draws, mapped into room coordinates. Re-derive
     it by running that hook; do not adjust it by eye.

     The first hand-written version of this rectangle was 360..580 and wrong in
     both directions at once — narrower than codex, whose six legs splay to
     333..606, and wide enough to swallow the pegboard's left edge, so a rule
     invented to stop collisions was itself colliding with two things. Measuring
     it also settled a question nobody had asked: the inner edge of every room's
     LEFT bay is inside codex's reach (bay L starts at 250-262 and codex reaches
     333), so a prop in the inner ~40px of a left bay can be stood in front of.
     Nothing there today needs to stay readable, and now that is a decision
     rather than an accident. */
  /* Re-measured after the JUGGERNAUT landed and was sized to the room
     (kimi series L16): at 1.05 the siege torso tucks back inside codex's
     splay, so the union is codex's width and floor line under claude's
     head top again — the same box the fleet had before kimi grew. */
  unit:["unit envelope",333,286,273,327],
  /* Nothing goes here, in any room. The ceiling is deliberately not on this
     list: the crane rail and the roof truss cross the lamp on purpose. */
  keep:[
    ["deck line",   250,596,760, 26]    // where every contact shadow lands
  ],
  /* What the floor already carries. x,y,w,h — including the parts that stand
     proud of the bench top, because that is what a new prop would hit. */
  deck:{
    builder :[["crates",182,558,66,72],["conveyor",580,558,222,54]],
    reviewer:[["verdict tower",632,496,14,116],
              ["doc stacks",690,586,56,26],["file cabinets",1040,554,72,58]],
    triage  :[["doc stack",700,586,26,26],
              ["phone bank",1042,582,40,30],["file cabinet",1086,554,34,58]]
  },
  /* The near plane: the deck station stands in FRONT of everything above,
     between the unit's feet and the camera, so it is not deck furniture and
     does not compete for deck space with it. One rectangle, all three rooms —
     the room decides what the object is, not where it stands. */
  near:["deck station",320,490,300,178],
  /* L6 — the station's company. One plane with one object in it reads as an
     object with a trick, not a plane; a second, humbler thing standing in it
     on the other side of frame is what makes the depth a fact about the room.
     Same depth, same grade, same glow-occlusion — the room decides what it
     is: spent stock by the fabricator, the archive going out, the slack the
     dispatch floor runs on. */
  /* L13 — plural now. One companion made the plane a fact; the left side of
     the frame was still empty floor, so the plane read as "station plus
     accessory" instead of as a layer the room actually lives in. The left
     props sit lower and humbler than the right ones — the frame needs a
     minor chord there, not a second drum. */
  nearSide:{
    builder :[["drum",938,560,64,116],["stock pallet",150,606,96,74]],
    reviewer:[["archive cart",930,556,74,120],["lab stool",168,586,64,94]],
    triage  :[["cable reel",934,566,72,110],["queue stanchions",148,592,110,88]]
  },
  /* Structure. `all` is every room; the rest are the room's own. */
  fixed:{
    all     :[["right tower",1150,372,66,240]],
    builder :[["crane rail",250,120,440,10]],
    reviewer:[],
    triage  :[]
  }
};
/* Everything bolted to the wall stands a few centimetres off it, and until now
   not one of them said so. `plate()` gives a prop its own internal shading and
   stops at its outline, so a monitor bank, a kanban board and a hazard placard
   all met the wall at a clean cut — which is the single clearest tell that
   this is a picture of props rather than props in a room. One soft offset
   shadow, down and away from the lamp, called at the top of each prop so it
   lands underneath. The offset grows with distance from the lamp, because the
   light is a point above LAMPX and not a studio softbox. */
function wallShadow(x,y,w,h,depth){
  var d=depth||1, dir=(x+w/2)<LAMPX?-1:1;
  var off=Math.min(11,3+Math.abs((x+w/2)-LAMPX)/95)*d;
  S.save();S.globalAlpha=0.34;S.filter="blur(3px)";
  S.fillStyle="#010307";S.fillRect(x+off*dir,y+3.5*d+off*0.55,w,h);
  S.restore();
}
var lamp={lit:1,drop:0};
var beaconPulse=0;   // set by drawRedBeacon each frame; read by the near plane
function stepLamp(t,dt,on){ if(reduced){lamp.lit=on?1:0;return;} if(!on){lamp.lit=0;return;} var base=0.86+0.14*fnoise(t*0.9); if(lamp.drop>0){lamp.drop-=dt;lamp.lit=0.12+0.08*Math.random();} else{lamp.lit=base;if(Math.random()<0.012)lamp.drop=0.04+Math.random()*0.12;} }
function emit(fn){fn(S);fn(G);}

/* ===================== BUILDER PROPS ===================== */
function crate(c,x,y){plate(c,[[x,y],[x+16,y],[x+16,y+14],[x,y+14]],"#3a2c1a","#160f08","#4a3826");c.fillStyle="rgba(201,162,39,0.4)";c.fillRect(x+2,y+3,12,2);}
function crateBig(x,y){plate(S,[[x,y],[x+42,y],[x+42,y+42],[x,y+42]],"#33271a","#130d07","#463526");S.strokeStyle="rgba(0,0,0,0.45)";S.lineWidth=1;S.strokeRect(x+6,y+6,30,30);S.fillStyle="rgba(201,162,39,0.32)";S.fillRect(x+8,y+17,26,3);S.fillStyle="rgba(255,200,140,0.05)";S.fillRect(x,y,42,2);}
function floorHazard(){var x=356,y=620,w=268;S.save();S.globalAlpha=0.5;for(var s=x;s<x+w;s+=18){S.fillStyle=(s-x)%36<18?"rgba(201,162,39,0.5)":"rgba(0,0,0,0)";S.fillRect(s,y,10,4);S.fillRect(s,y+40,10,4);}S.restore();S.strokeStyle="rgba(201,162,39,0.14)";S.lineWidth=1;S.strokeRect(x,y,w,40);}
function crane(t){
  var railY=120,x0=250,x1=690;
  S.fillStyle="#121826";S.fillRect(x0,railY,x1-x0,10);S.fillStyle="#222d3c";S.fillRect(x0,railY,x1-x0,3);
  for(var i=x0+10;i<x1;i+=40){S.fillStyle="#0a0f16";S.fillRect(i,railY+10,6,4);}
  var tx=470;  // static + integer-aligned: a striped girder can't move without its edges aliasing
  S.fillStyle="#28303c";S.fillRect(tx-14,railY-2,28,14);
  S.strokeStyle="#3a465e";S.lineWidth=2;S.beginPath();S.moveTo(tx,railY+12);S.lineTo(tx,railY+70);S.stroke();
  S.fillStyle="#1a2230";S.fillRect(tx-8,railY+70,16,10);
  // the hook's warning light is the living element (a smooth glow — no aliasing)
  emit(function(c){var p=0.35+0.65*Math.pow(Math.max(0,Math.sin(t*2)),2);c.fillStyle=rgba(255,60,50,0.9*p);c.beginPath();c.arc(tx,railY+80,2.5,0,7);c.fill();var g7=c.createRadialGradient(tx,railY+80,1,tx,railY+80,10);g7.addColorStop(0,rgba(255,60,50,0.5*p));g7.addColorStop(1,"rgba(255,60,50,0)");c.fillStyle=g7;c.beginPath();c.arc(tx,railY+80,10,0,7);c.fill();});
  var gy=railY+92;for(var s=tx-56;s<tx+56;s+=14){S.fillStyle=((s-tx+56)%28<14)?"#c9a227":"#0f1420";S.fillRect(s,gy,14,12);}
  S.fillStyle="rgba(0,0,0,0.4)";S.fillRect(tx-60,gy+12,120,3);
  /* The crane was carrying nothing. A gantry with an empty hook, parked dead
     centre over the work, is set dressing; a slung girder on two slings is the
     bay telling you what it is for. Static and integer-aligned for the same
     reason the trolley is — a striped mass that drifts aliases its own edges. */
  var slY=gy+15;
  S.strokeStyle="#1b2432";S.lineWidth=2;
  S.beginPath();S.moveTo(tx-40,slY);S.lineTo(tx-52,slY+30);S.moveTo(tx+40,slY);S.lineTo(tx+52,slY+30);S.stroke();
  plate(S,[[tx-58,slY+30],[tx+58,slY+30],[tx+58,slY+41],[tx-58,slY+41]],"#2b3444","#141b26","#3b4a60");
  S.fillStyle="rgba(0,0,0,0.45)";S.fillRect(tx-58,slY+35,116,2);
  S.fillStyle="rgba(150,175,210,0.14)";S.fillRect(tx-58,slY+30,116,1.5);
  S.fillStyle="rgba(201,162,39,0.35)";S.fillRect(tx-26,slY+33,20,4);
}
function rightTower(t){
  var x=1150,w=66,yb=612,yt=372,seg=(yb-yt-26)/9;
  plate(S,[[x,yt],[x+w,yt],[x+w,yb],[x,yb]],"#141b28","#080c14","#20303f");
  S.fillStyle="#20293a";S.fillRect(x,yt,w,5);
  for(var u=0;u<9;u++){var uy=yt+14+u*seg;S.fillStyle="#0a0f18";S.fillRect(x+7,uy,w-14,seg-3);S.fillStyle="#12203a";S.fillRect(x+9,uy+1,10,2);
    if(u%2===0){var on=Math.sin(t*2+u)>0.2;var col=[[95,206,155],[95,180,255],[247,189,78]][u%3];emit(function(c){c.fillStyle=rgba(col[0],col[1],col[2],(on?0.62:0.14));c.fillRect(x+w-13,uy+2,4,3);});}
  }
  // side rim sliver + a faint key-light spill so it isn't pure black
  emit(function(c){c.fillStyle="rgba(95,214,255,0.10)";c.fillRect(x-1,yt,1,yb-yt);});
  S.fillStyle="rgba(120,150,180,0.05)";S.fillRect(x,yt,4,yb-yt);
  // hanging cable up to ceiling
  S.strokeStyle="#0d1520";S.lineWidth=3;S.beginPath();S.moveTo(x+w-10,yt);S.quadraticCurveTo(x+w+16,yt-46,x+w+8,yt-96);S.stroke();
  contactShadow(x+w/2,yb,w);
}
function contactShadow(cx,by,w){S.save();var g2=S.createRadialGradient(cx,by,2,cx,by,w*0.8);g2.addColorStop(0,"rgba(0,0,0,0.5)");g2.addColorStop(1,"rgba(0,0,0,0)");S.fillStyle=g2;S.beginPath();S.ellipse(cx,by+2,w*0.7,10,0,0,7);S.fill();S.restore();}
function fabBay(t,lit,st){
  var x=258,w=114,yt=430,yb=612,on=st!=="offline";
  plate(S,[[x,yt],[x+w,yt],[x+w,yb],[x,yb]],"#1b2330","#090d14","#2a3444");
  S.fillStyle="rgba(201,162,39,0.5)";S.fillRect(x+6,yt+6,w-12,8);
  var cxa=x+16,cya=yt+28,cw=w-32,ch=112;
  S.fillStyle="#04070c";S.fillRect(cxa,cya,cw,ch);S.strokeStyle="#2a3444";S.lineWidth=1;S.strokeRect(cxa,cya,cw,ch);
  var head=0.5+0.5*Math.sin(t*(st==="working"?4:1)),px=cxa+8+head*(cw-24);
  emit(function(c){if(!on)return;var pg=c.createLinearGradient(0,cya+ch-44,0,cya+ch);pg.addColorStop(0,rgba(255,180,90,0.7*(st==="working"?1:0.5)));pg.addColorStop(1,rgba(255,120,40,0.2));c.fillStyle=pg;c.fillRect(cxa+cw/2-10,cya+ch-46,20,42);
    c.fillStyle=rgba(150,210,255,st==="working"?0.9:0.3);c.fillRect(px,cya+18,3,3);
    var ig=c.createRadialGradient(cxa+cw/2,cya+ch-22,2,cxa+cw/2,cya+ch-22,cw*0.7);ig.addColorStop(0,rgba(255,160,70,0.28*(st==="working"?1:0.45)));ig.addColorStop(1,"rgba(255,160,70,0)");c.fillStyle=ig;c.fillRect(cxa,cya,cw,ch);});
  S.strokeStyle="#3a465e";S.lineWidth=1;S.beginPath();S.moveTo(cxa+4,cya+16);S.lineTo(cxa+cw-4,cya+16);S.stroke();
  S.fillStyle="#28303c";S.fillRect(px-1,cya+14,5,5);
  /* Bay shutter. With the box silent the furnace is not merely unlit — the bay
     is closed. Slats over the chamber turn "this prop is dark" into "this prop
     is shut", which is a different and more useful thing to read from across
     a grid of thumbnails. */
  if(!on){S.fillStyle="#0b1017";S.fillRect(cxa,cya,cw,ch);
    for(var sl3=0;sl3<ch;sl3+=7){S.fillStyle="#161d27";S.fillRect(cxa+1,cya+sl3,cw-2,5);S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(cxa+1,cya+sl3+5,cw-2,2);}
    S.strokeStyle="#2a3444";S.lineWidth=1;S.strokeRect(cxa,cya,cw,ch);
    S.fillStyle="rgba(255,70,58,0.30)";S.fillRect(cxa+cw/2-9,cya+ch/2-2,18,4);}
  emit(function(c){c.fillStyle=on?rgba(95,206,155,0.9):rgba(255,60,50,0.8);c.beginPath();c.arc(x+w-12,yt+22,3,0,7);c.fill();});
  /* The furnace throws light on the floor in front of it. It was the brightest
     thing in the bay and the concrete two feet away was as dark as the corner
     of the room — the one change that stops the fabricator reading as a
     picture of a fire hung on the wall. */
  if(on){S.save();S.globalCompositeOperation="lighter";
    var spill=S.createRadialGradient(x+w/2,FLOORY,4,x+w/2,FLOORY,190);
    var sk=(st==="working"?1:0.5);
    spill.addColorStop(0,"rgba(255,150,60,"+(0.20*sk)+")");
    spill.addColorStop(0.45,"rgba(230,110,40,"+(0.08*sk)+")");
    spill.addColorStop(1,"rgba(200,90,30,0)");
    S.fillStyle=spill;S.beginPath();S.ellipse(x+w/2,FLOORY+8,190,34,0,0,7);S.fill();S.restore();}
  rivet(S,x+6,yt+3,"#3d4c63");rivet(S,x+w-6,yt+3,"#3d4c63");
  // barrels beside the bay
  [[x+w+6,"#c9a227"],[x+w+18,"#4f9e5a"]].forEach(function(k){var bx=k[0];plate(S,[[bx,566],[bx+11,566],[bx+11,612],[bx,612]],k[1],"#0c1119","#0a0e16");S.fillStyle="rgba(0,0,0,0.4)";S.fillRect(bx,576,11,1);S.fillRect(bx,596,11,1);});
}
/* BAYS.builder.L — gas bottles.
   The fabricator has been throwing a furnace flame since loop 3 and nothing in
   the room has ever supplied it. Two cylinders strapped to the wall directly
   above the bay, with regulators and a hose dropping toward it, is the prop
   that makes the fire an installation rather than an effect. */
function gasRack(t,lit,st){
  var x=272,y=214,off=st==="offline";
  wallShadow(x-6,y-8,104,180);
  // backboard + two strap rails
  plate(S,[[x-6,y-8],[x+98,y-8],[x+98,y+172],[x-6,y+172]],"#1a212c","#0c111a","#28313f");
  [[y+26],[y+118]].forEach(function(r){S.fillStyle="#39455a";S.fillRect(x-4,r[0],100,5);
    S.fillStyle="rgba(190,214,246,"+(0.10*lit)+")";S.fillRect(x-4,r[0],100,1);});
  [[x+8,"#4a5a3c","#7f9a5e"],[x+52,"#4a2f2c","#9a5f4e"]].forEach(function(k){
    var bx=k[0];
    // body: a cylinder, so a horizontal gradient not a vertical one
    var cyl=S.createLinearGradient(bx,0,bx+38,0);
    cyl.addColorStop(0,"#0d1219");cyl.addColorStop(0.34,k[1]);cyl.addColorStop(0.52,k[2]);
    cyl.addColorStop(0.72,k[1]);cyl.addColorStop(1,"#0a0e14");
    rr(S,bx,y+8,38,156,7);S.fillStyle=cyl;S.fill();
    S.strokeStyle="#0a0e14";S.lineWidth=1.2;rr(S,bx,y+8,38,156,7);S.stroke();
    S.fillStyle="rgba(210,228,255,"+(0.13*lit)+")";S.fillRect(bx+11,y+14,3,144);   // specular strip
    // shoulder, valve, regulator dial
    plate(S,[[bx+9,y+8],[bx+29,y+8],[bx+26,y-6],[bx+12,y-6]],"#2a3242","#141a24","#3c4658");
    S.fillStyle="#39455a";S.fillRect(bx+16,y-14,6,9);
    S.fillStyle="#0c121a";S.beginPath();S.arc(bx+19,y-20,7,0,7);S.fill();
    S.strokeStyle="#46536a";S.lineWidth=1.2;S.beginPath();S.arc(bx+19,y-20,7,0,7);S.stroke();
    if(!off){emit(function(c){c.strokeStyle="rgba(120,220,170,0.6)";c.lineWidth=1.4;
      c.beginPath();c.moveTo(bx+19,y-20);c.lineTo(bx+19+4,y-25);c.stroke();});}
    // strap over each rail
    S.fillStyle="rgba(20,26,36,0.9)";S.fillRect(bx-2,y+24,42,9);S.fillRect(bx-2,y+116,42,9);
    S.fillStyle="rgba(140,160,190,0.12)";S.fillRect(bx-2,y+24,42,1);S.fillRect(bx-2,y+116,42,1);});
  // the hose, running down out of the bay toward the fabricator
  S.strokeStyle="#0c1119";S.lineWidth=5;
  S.beginPath();S.moveTo(x+71,y-16);S.bezierCurveTo(x+104,y+30,x+58,y+152,x+66,y+206);S.stroke();
  S.strokeStyle="rgba(78,92,116,0.45)";S.lineWidth=1.4;
  S.beginPath();S.moveTo(x+71,y-16);S.bezierCurveTo(x+104,y+30,x+58,y+152,x+66,y+206);S.stroke();
  // a chained-up spare, empty, tipped against the board
  S.strokeStyle="rgba(96,112,138,0.5)";S.lineWidth=1;
  S.beginPath();S.moveTo(x-4,y+150);S.lineTo(x+98,y+156);S.stroke();
}
/* BAYS.builder.R — the fire point.
   A bay that welds, throws sparks onto a deck and stores gas has an
   extinguisher on the wall, and this one had a hazard placard warning about a
   danger with no answer to it anywhere in the room. It goes directly under the
   placard, which is what turns two props into one piece of signage. */
function firePoint(t,lit,st){
  var x=812,y=428,off=st==="offline";
  wallShadow(x,y,118,110);
  /* Muted, deliberately. The first cut used workshop-red at full saturation
     and became the brightest object in the bay — a fire point should be
     findable, not the thing you look at instead of the unit under the lamp.
     Enough red to read as safety equipment from across the room, and no more. */
  plate(S,[[x,y],[x+118,y],[x+118,y+110],[x,y+110]],"#201214","#12090b","#38191c");
  S.fillStyle="rgba(196,72,58,"+(off?0.07:0.15)+")";S.fillRect(x+6,y+6,106,4);
  // extinguisher
  var ex=x+16;
  var eg2=S.createLinearGradient(ex,0,ex+26,0);
  eg2.addColorStop(0,"#2c0d0f");eg2.addColorStop(0.36,"#6d1e19");eg2.addColorStop(0.54,"#95352c");
  eg2.addColorStop(0.76,"#5d1a15");eg2.addColorStop(1,"#220a0c");
  rr(S,ex,y+34,26,62,5);S.fillStyle=eg2;S.fill();
  S.fillStyle="rgba(255,222,206,"+(0.11*lit)+")";S.fillRect(ex+8,y+38,3,54);
  plate(S,[[ex+7,y+34],[ex+19,y+34],[ex+17,y+24],[ex+9,y+24]],"#2a3242","#141a24","#3c4658");
  S.strokeStyle="#39455a";S.lineWidth=2.4;S.beginPath();S.moveTo(ex+13,y+24);S.lineTo(ex+30,y+30);S.stroke();
  S.fillStyle="rgba(236,224,200,0.5)";S.fillRect(ex+4,y+56,18,10);
  S.fillStyle="rgba(0,0,0,0.4)";for(var fl=0;fl<3;fl++)S.fillRect(ex+6,y+59+fl*3,14-(fl%2)*5,1.4);
  // hose reel
  var rx=x+66,ry=y+58;
  S.fillStyle="#151b25";S.beginPath();S.arc(rx,ry,25,0,7);S.fill();
  S.strokeStyle="#39455a";S.lineWidth=2;S.beginPath();S.arc(rx,ry,25,0,7);S.stroke();
  S.strokeStyle="rgba(66,78,98,0.85)";S.lineWidth=3;
  for(var hr=0;hr<4;hr++){S.beginPath();S.arc(rx,ry,7+hr*4.5,0,7);S.stroke();}
  S.fillStyle="rgba(190,214,246,"+(0.11*lit)+")";S.beginPath();S.arc(rx-8,ry-9,4,0,7);S.fill();
  S.fillStyle="#0e131b";S.beginPath();S.arc(rx,ry,5,0,7);S.fill();
  // call point, live only when the box is
  emit(function(c){c.fillStyle=off?"rgba(90,26,22,0.7)":"rgba(255,74,58,"+(0.35+0.45*Math.pow(Math.max(0,Math.sin(t*1.1)),4))+")";
    c.fillRect(x+96,y+34,12,12);});
  S.strokeStyle="rgba(120,60,52,0.6)";S.lineWidth=1;S.strokeRect(x+95,y+33,14,14);
}
function pegboard(t,lit){
  var x=560,y=250,w=94,h=70;
  wallShadow(x,y,w,h);
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#2a1f12","#160f08","#3a2c1a");
  S.fillStyle="rgba(0,0,0,0.4)";for(var i=0;i<7;i++)for(var j=0;j<4;j++)S.fillRect(x+10+i*11,y+9+j*14,2,2);
  var tc=["#8a939e","#c9a227","#b0563a","#5a9e6a"];
  for(var k=0;k<4;k++){var tx=x+14+k*20;S.fillStyle="#0a0f16";S.fillRect(tx,y+12,3,32);S.fillStyle=tc[k];S.fillRect(tx-3,y+38,9,10);}
  S.fillStyle="rgba(255,200,140,"+(0.06*lit)+")";S.fillRect(x,y,w,2);
}
function conveyor(t,st){
  /* x was 566, which put ten pixels of belt through the workbench top at
     x=372..576. Four pixels tall, both surfaces dark, invisible for fifteen
     loops and found the moment the deck was written down. See LAYOUT. */
  var x=580,y=558,w=222,run=st==="working";
  S.fillStyle="#0f1520";S.fillRect(x+12,y+12,8,42);S.fillRect(x+w-20,y+12,8,42);
  plate(S,[[x,y],[x+w,y],[x+w,y+12],[x,y+12]],"#202836","#0d131e","#2a3444");
  var off=run?(t*40)%16:0;S.fillStyle="#0a0f16";S.fillRect(x+2,y+3,w-4,7);
  S.fillStyle="#161d29";for(var i=x+2-16+off;i<x+w;i+=16)S.fillRect(i,y+3,8,7);
  /* Running, the crates are spread evenly along the belt. Stopped, they bunch
     against the head of the line — which is what a halted conveyor looks like,
     and what makes a stopped bay read as *backed up* rather than merely quiet.
     Idle here means work is waiting, and the belt should say so. */
  if(run){var coff=(t*40)%80;for(var c=0;c<3;c++){var cx2=x+10+((c*80+coff)%(w-26));crate(S,cx2,y-14);}}
  else{for(var c2=0;c2<4;c2++)crate(S,x+w-34-c2*19,y-14);}
  emit(function(cc){cc.fillStyle=run?rgba(95,206,155,0.9):rgba(120,130,140,0.35);cc.beginPath();cc.arc(x+6,y+6,2.5,0,7);cc.fill();});
}

/* ===================== REVIEWER PROPS (clinical lab) ===================== */
function diffWall(t,st){
  var x=262,y=176,mw=80,gap=12,mh=132,off=st==="offline",scroll=off?0:(t*(st==="working"?20:6));
  for(var i=0;i<4;i++){var mx=x+i*(mw+gap);
    wallShadow(mx,y,mw,mh,1.2);
    plate(S,[[mx,y],[mx+mw,y],[mx+mw,y+mh],[mx,y+mh]],"#0c1220","#060a12","#22304a");
    S.fillStyle="#07121e";S.fillRect(mx+4,y+4,mw-8,mh-8);
    if(off){
      /* Standby, not "the same diff but dimmer". A review station whose box
         has gone silent is showing no signal — a centre bar and a lone standby
         LED — and dimming the code instead said the review was still running,
         quietly, which is the opposite of true. */
      S.fillStyle="rgba(120,140,170,0.16)";S.fillRect(mx+10,y+mh/2-1,mw-20,2);
      S.fillStyle="rgba(120,140,170,0.06)";S.fillRect(mx+18,y+mh/2+7,mw-36,1);
    } else
    for(var l=0;l<17;l++){var ly=y+8+((l*9+scroll)%(mh-14));var k=(i+l)%4;var cr=k===0?90:k===1?210:70,cg=k===0?200:k===1?90:110,cb=k===0?120:k===1?90:150;var lw=Math.min(14+((i*7+l*13)%48),mw-14);S.fillStyle=rgba(cr,cg,cb,0.5);S.fillRect(mx+7,ly,lw,2);G.fillStyle=rgba(cr,cg,cb,0.34);G.fillRect(mx+7,ly,lw,2);}
    if(!off){var gg=S.createRadialGradient(mx+mw/2,y+mh/2,4,mx+mw/2,y+mh/2,mw*0.9);gg.addColorStop(0,"rgba(90,160,220,0.09)");gg.addColorStop(1,"rgba(90,160,220,0)");S.fillStyle=gg;S.fillRect(mx-8,y-8,mw+16,mh+16);}
    S.fillStyle=off?"#3a1518":"#1a3a2a";S.fillRect(mx+mw-11,y+mh-6,6,3);
  }
  /* Four lit monitors light the wall they are bolted to. The panel behind them
     was the same near-black as the unlit half of the room, which is what made
     this wall read as a poster of monitors rather than monitors in a room. */
  if(!off){S.save();S.globalCompositeOperation="lighter";
    var ww2=x+3*(mw+gap)+mw, wash=S.createLinearGradient(0,y-30,0,y+mh+120);
    wash.addColorStop(0,"rgba(90,160,230,0)");
    wash.addColorStop(0.3,"rgba(90,160,230,"+(st==="working"?0.075:0.045)+")");
    wash.addColorStop(1,"rgba(90,160,230,0)");
    S.fillStyle=wash;S.fillRect(x-40,y-30,(ww2-x)+80,mh+150);S.restore();}
}
/* It was at (566,252), which put its top-left quarter over the fourth diff
   monitor — a clipboard hung on a screen. Moved right, into the gap between
   the monitor bank and the certification plates, where it reads as the step
   between the two: what was checked, then what was signed. */
function checklistBoard(){
  var x=676,y=290,w=88,h=76;wallShadow(x,y,w,h);plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#0f1620","#0a0f16","#22304a");S.fillStyle="#131c26";S.fillRect(x+5,y+5,w-10,h-10);
  for(var i=0;i<6;i++){S.fillStyle=i<4?"#4a8a5e":"#38424e";S.fillRect(x+9,y+11+i*11,4,4);S.fillStyle="#39434f";S.fillRect(x+17,y+12+i*11,w-28,2);}
}
/* BAYS.reviewer.L — the calibration chart.
   A lab whose whole job is looking closely at things had nothing on its wall
   for checking that it can still see. A test card is the one object that says
   "the instruments here are trusted because they are verified" — and it is
   also the only prop in the fleet whose content is a measurement rather than a
   readout: greyscale wedge, resolution wedges, registration crosses. It does
   not animate, because a calibration target that moved would be useless. */
function calChart(t,lit,st){
  var x=272,y=352,w=142,h=136,off=st==="offline";
  wallShadow(x,y,w,h);
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#1c242e","#0d131a","#2c3948");
  S.fillStyle="#c9d3df";S.fillRect(x+7,y+7,w-14,h-14);
  S.fillStyle="rgba(20,30,42,0.86)";S.fillRect(x+7,y+7,w-14,h-14);
  // greyscale wedge — eleven steps, the classic
  /* The wedge tops out at 60% rather than at white. A calibration target is
     printed, and a printed white in a room lit to 12% is not paper-white — it
     was reading as a lightbox and taking the eye off the unit. */
  for(var g4=0;g4<11;g4++){var v=Math.round(14+g4*13.4);
    S.fillStyle="rgb("+v+","+(v+3)+","+(v+8)+")";S.fillRect(x+12+g4*10.8,y+13,10.2,20);}
  // resolution wedges: two blocks of converging bars
  [[x+13,y+41],[x+78,y+41]].forEach(function(b,bi){
    for(var l3=0;l3<9;l3++){var lw3=(bi?0.9:1.5)+l3*0.34;
      S.fillStyle="rgba(206,220,236,0.42)";S.fillRect(b[0]+l3*6.4,b[1],lw3,26);}});
  // registration crosses at the corners of the field
  [[x+16,y+80],[x+w-16,y+80],[x+16,y+h-16],[x+w-16,y+h-16]].forEach(function(c4){
    S.strokeStyle="rgba(206,220,236,0.5)";S.lineWidth=1;
    S.beginPath();S.moveTo(c4[0]-6,c4[1]);S.lineTo(c4[0]+6,c4[1]);
    S.moveTo(c4[0],c4[1]-6);S.lineTo(c4[0],c4[1]+6);S.stroke();});
  // a colour patch row and the plate's serial
  ["#b0563a","#4f9e5a","#4a7cc9","#c9a227"].forEach(function(cc,ci){
    S.fillStyle=cc;S.globalAlpha=0.38;S.fillRect(x+34+ci*20,y+96,17,17);S.globalAlpha=1;});
  S.fillStyle="rgba(150,175,205,0.24)";S.fillRect(x+34,y+120,74,2);
  // and the desk lamp finds it, faintly, from the right
  if(!off){S.save();S.globalCompositeOperation="lighter";
    var cw2=S.createLinearGradient(x+w,0,x,0);
    cw2.addColorStop(0,"rgba(150,196,245,0.055)");cw2.addColorStop(1,"rgba(150,196,245,0)");
    S.fillStyle=cw2;S.fillRect(x,y,w,h);S.restore();}
}
/* BAYS.reviewer.R — the sample archive.
   Everything this room does ends with something being filed: loop 10 gave the
   lens a specimen to look at, loop 8 gave the wall plates to sign, and there
   was nowhere for any of it to go afterwards. Small labelled drawers, three of
   them pulled, one lit from inside. */
function sampleArchive(t,lit,st){
  var x=700,y=440,off=st==="offline";
  wallShadow(x,y,280,104);
  plate(S,[[x,y],[x+280,y],[x+280,y+104],[x,y+104]],"#151d28","#0a0f16","#25313f");
  for(var r4=0;r4<3;r4++)for(var c5=0;c5<7;c5++){
    var dx2=x+8+c5*39, dy2=y+8+r4*31, pull=(r4*7+c5)%11===3;
    plate(S,[[dx2,dy2],[dx2+35,dy2],[dx2+35,dy2+27],[dx2,dy2+27]],
      pull?"#22303f":"#131b25","#080d14","#22303f");
    if(pull){                                     // pulled out: a lit slot behind
      S.fillStyle="rgba(2,5,10,0.8)";S.fillRect(dx2-3,dy2+2,4,23);
      if(!off)emit(function(c){c.fillStyle="rgba(130,190,250,0.20)";c.fillRect(dx2-3,dy2+2,3,23);});}
    S.fillStyle="rgba(160,186,214,"+(0.16*lit)+")";S.fillRect(dx2+1,dy2+1,33,1);
    S.fillStyle="#39455a";S.fillRect(dx2+13,dy2+12,9,3);               // handle
    S.fillStyle="rgba(206,220,236,0.20)";S.fillRect(dx2+4,dy2+5,16,3); // label
    if((r4+c5)%4===0&&!off)emit(function(c){
      c.fillStyle="rgba(79,208,122,0.55)";c.fillRect(dx2+29,dy2+20,3,3);});}
}
function verdictTower(t,st){
  var x=632,pt=496,baseY=612;
  S.fillStyle="#0f1520";S.fillRect(x+4,pt+48,6,baseY-(pt+48));
  contactShadow(x+7,baseY,26);
  plate(S,[[x,pt],[x+14,pt],[x+14,pt+48],[x,pt+48]],"#141b26","#0a0f16","#22304a");
  var LT=[["255,77,71",st==="offline"],["247,189,78",st==="working"],["79,208,122",st==="idle"]];
  for(var i=0;i<3;i++){var ly=pt+4+i*15,on=LT[i][1],col=LT[i][0];
    if(on)emit(function(c){c.fillStyle="rgba("+col+",0.92)";c.fillRect(x+3,ly,8,10);var g4=c.createRadialGradient(x+7,ly+5,1,x+7,ly+5,16);g4.addColorStop(0,"rgba("+col+",0.5)");g4.addColorStop(1,"rgba("+col+",0)");c.fillStyle=g4;c.beginPath();c.arc(x+7,ly+5,16,0,7);c.fill();});
    else{S.fillStyle="#0e141c";S.fillRect(x+3,ly,8,10);}
  }
}
function fileCabinet(x){var y=612-58;plate(S,[[x,y],[x+34,y],[x+34,612],[x,612]],"#2a3340","#12181f","#3a4656");for(var d=0;d<3;d++){S.fillStyle="#0e141c";S.fillRect(x+4,y+7+d*17,26,13);S.fillStyle="#5a6a80";S.fillRect(x+13,y+12+d*17,8,2);}contactShadow(x+17,612,34);}
function docStack(x){for(var i=0;i<5;i++){S.fillStyle=i%2?"#cbd4e0":"#adb8c6";S.fillRect(x-(i%2),612-6-i*4,26,4);}S.fillStyle="rgba(0,0,0,0.3)";S.fillRect(x,612-2,26,2);}

/* ===================== TRIAGE PROPS (dispatch room) ===================== */
function kanban(t,st){
  var x=268,y=178,w=344,h=128,off=st==="offline",colw=(w-24)/4;
  wallShadow(x,y,w,h,1.25);
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#20262e","#0e1216","#3a4048");
  S.fillStyle="#2f353c";S.fillRect(x+6,y+6,w-12,h-12);S.fillStyle="#3a4149";S.fillRect(x+6,y+6,w-12,1);
  /* Chipped frame. This board is the one object in the fleet that gets touched
     by hand all day — cards pinned, moved, pulled — and it was rendering as
     factory-fresh extruded aluminium. The paint goes first at the corners and
     along the bottom rail where hands rest. */
  S.save();S.globalAlpha=off?0.3:0.75;
  [[x+3,y+3,9,3],[x+w-13,y+3,10,3],[x+3,y+h-6,7,3],[x+w-11,y+h-6,8,3],
   [x+w*0.34,y+h-5,22,2],[x+w*0.58,y+h-5,15,2],[x+2,y+h*0.4,3,14]].forEach(function(ch){
    S.fillStyle="rgba(126,136,148,0.5)";S.fillRect(ch[0],ch[1],ch[2],ch[3]);});
  S.restore();
  var cols=["247,189,78","92,180,255","201,139,255","95,206,155"];
  for(var c=0;c<4;c++){var cx2=x+12+c*colw;S.fillStyle="#242a30";S.fillRect(cx2,y+10,1,h-20);
    S.fillStyle="rgba("+cols[c]+","+(off?0.3:0.6)+")";S.fillRect(cx2+6,y+13,colw-14,3);
    /* Idle triage is not an empty board — it is an unworked one. Working, the
       cards are spread across all four columns and move; idle, they pile up in
       the intake column and the other three run nearly dry. The board is the
       only thing in this room that can show a backlog, so it should. */
    var n=off?2:(st==="working"?(2+((c+Math.floor(t))%3)):(c===0?5:1));
    for(var k=0;k<n;k++){var cc=cols[(c+k)%4];S.fillStyle="rgba("+cc+","+(off?0.18:0.48)+")";S.fillRect(cx2+6,y+22+k*15,colw-14,11);S.fillStyle="rgba(0,0,0,0.3)";S.fillRect(cx2+6,y+22+k*15,colw-14,1);}
  }
  /* The board is a metre-wide lit panel and the wall under it was black. It
     spills a cool wash downward — and unlike the other two rooms this one is
     colourless on purpose: the board's own colours are its data, and tinting
     the room with them would make the wall look like it meant something. */
  if(!off){S.save();S.globalCompositeOperation="lighter";
    var kw=S.createLinearGradient(0,y+h,0,y+h+150);
    kw.addColorStop(0,"rgba(150,175,205,"+(st==="working"?0.07:0.05)+")");
    kw.addColorStop(1,"rgba(150,175,205,0)");
    S.fillStyle=kw;S.fillRect(x-30,y+h,w+60,150);S.restore();}
}
/* Moved out of the signage bay, and down into a column with the zone clocks
   and under the work-order board: instruments together, paper together. It
   used to sit at (690,248) — dead centre of the room's own name, with the
   sweep passing over the letters. */
/* BAYS.triage.L — the pneumatic tube.
   Dispatch is the room that moves things to people, and it did it entirely
   through screens: a kanban board, a radar, a phone. A tube station is the one
   piece of dispatch furniture that is physically about transit — you can see
   the thing being sent. A carrier rises through the run while the box is
   working, arrives at the head, and the head lamp answers. */
function tubeStation(t,lit,st){
  var x=286,off=st==="offline",work=st==="working";
  var yt=330,yb=524;
  wallShadow(x-4,yt,52,yb-yt);
  // the run: a glass column in a steel frame
  plate(S,[[x-4,yt],[x+48,yt],[x+48,yb],[x-4,yb]],"#1a212c","#0c111a","#2a3444");
  S.fillStyle="#050a10";S.fillRect(x+6,yt+8,32,yb-yt-16);
  var tg=S.createLinearGradient(x+6,0,x+38,0);
  tg.addColorStop(0,"rgba(150,180,220,0.10)");tg.addColorStop(0.3,"rgba(150,180,220,0.02)");
  tg.addColorStop(0.62,"rgba(190,214,246,"+(0.20*lit)+")");tg.addColorStop(1,"rgba(150,180,220,0.05)");
  S.fillStyle=tg;S.fillRect(x+6,yt+8,32,yb-yt-16);
  /* Two collars, not five. At 44px spacing they read as ladder rungs — the
     prop said "climb me" in a room with nothing to climb to. A tube has a
     joint where it passes each floor and nowhere else. */
  [yt+58,yb-74].forEach(function(cl3){
    S.fillStyle="#2c3646";S.fillRect(x-1,cl3,46,9);
    S.fillStyle="rgba(190,214,246,"+(0.14*lit)+")";S.fillRect(x-1,cl3,46,1.4);
    S.fillStyle="rgba(2,5,10,0.5)";S.fillRect(x-1,cl3+7.6,46,1.6);});
  // the carrier, in transit while there is work moving
  if(!off){var ph2=work?((t*0.42)%1):0.86, cy4=yb-24-ph2*(yb-yt-56);
    plate(S,[[x+11,cy4],[x+33,cy4],[x+33,cy4+26],[x+11,cy4+26]],"#3b4658","#1d2532","#556277");
    S.fillStyle="rgba(201,162,39,0.7)";S.fillRect(x+13,cy4+6,18,4);
    S.fillStyle="rgba(220,236,255,0.16)";S.fillRect(x+14,cy4+2,16,1.6);
    if(work)emit(function(c){var bg3=c.createLinearGradient(0,cy4+26,0,cy4+58);
      bg3.addColorStop(0,"rgba(186,150,255,0.16)");bg3.addColorStop(1,"rgba(186,150,255,0)");
      c.fillStyle=bg3;c.fillRect(x+8,cy4+26,28,32);});}
  // send/receive head at the top, with its own lamp
  plate(S,[[x-10,yt-34],[x+54,yt-34],[x+50,yt],[x-6,yt]],"#232c39","#101720","#37445a");
  S.fillStyle="#0a0f16";S.fillRect(x+4,yt-26,36,14);
  emit(function(c){var on3=!off&&(work?(Math.sin(t*3.4)>-0.2):(Math.sin(t*0.9)>0.6));
    c.fillStyle="rgba(186,150,255,"+(on3?0.8:0.14)+")";c.fillRect(x+7,yt-23,30,8);});
  S.fillStyle="rgba(190,214,246,"+(0.12*lit)+")";S.fillRect(x-10,yt-34,64,1.6);
  // and the floor flange it lands on
  plate(S,[[x-10,yb],[x+54,yb],[x+50,yb+14],[x-6,yb+14]],"#222b37","#0e141c","#33404f");
}
/* BAYS.triage.R — the duty roster.
   The room routes work to people and named nobody. Six slots, each a plate in
   a rail with a shift lamp: on duty, on call, off. It is the only prop in the
   fleet that is about who rather than what, which is the whole difference
   between a dispatch desk and a status screen. */
function dutyBoard(t,lit,st){
  var x=846,y=436,w=140,h=104,off=st==="offline";
  wallShadow(x,y,w,h);
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#1d2029","#0d1014","#333846");
  S.fillStyle="rgba(190,214,246,"+(0.10*lit)+")";S.fillRect(x,y,w,1.4);
  for(var d3=0;d3<6;d3++){
    var ry2=y+9+d3*15.5, on4=off?0:[1,1,2,0,1,2][d3];
    S.fillStyle="#0f131a";S.fillRect(x+7,ry2,w-14,12);
    S.fillStyle="rgba(198,212,232,0.20)";S.fillRect(x+11,ry2+3,44+((d3*13)%22),3);   // the name
    S.fillStyle="rgba(150,170,196,0.12)";S.fillRect(x+11,ry2+8,26,1.4);
    var col2=on4===1?"79,208,122":on4===2?"247,189,78":"70,80,96";
    emit(function(c){c.fillStyle="rgba("+col2+","+(on4?0.75:0.3)+")";
      c.fillRect(x+w-18,ry2+4,6,5);});}
  S.fillStyle="rgba(186,150,255,"+(off?0.06:0.16)+")";S.fillRect(x+7,y+h-8,w-14,2.4);
}
function radar(t,st){
  var cx2=706,cy2=478,r=34,off=st==="offline";
  wallShadow(cx2-r*0.82,cy2-r*0.82,r*1.64,r*1.64);
  S.fillStyle="#0a1016";S.beginPath();S.arc(cx2,cy2,r,0,7);S.fill();
  S.strokeStyle="rgba(95,206,155,0.25)";S.lineWidth=1;for(var i=1;i<=3;i++){S.beginPath();S.arc(cx2,cy2,r*i/3,0,7);S.stroke();}
  S.beginPath();S.moveTo(cx2-r,cy2);S.lineTo(cx2+r,cy2);S.moveTo(cx2,cy2-r);S.lineTo(cx2,cy2+r);S.stroke();
  if(!off){var a=t*1.5;emit(function(c){c.save();c.globalCompositeOperation="lighter";
    c.fillStyle="rgba(95,206,155,0.18)";c.beginPath();c.moveTo(cx2,cy2);c.arc(cx2,cy2,r,a-0.5,a);c.closePath();c.fill();
    c.strokeStyle="rgba(120,240,180,0.7)";c.lineWidth=1.5;c.beginPath();c.moveTo(cx2,cy2);c.lineTo(cx2+Math.cos(a)*r,cy2+Math.sin(a)*r);c.stroke();
    [[0.5,1.2],[0.72,2.8],[0.4,4.6]].forEach(function(b){var bx=cx2+Math.cos(b[1])*r*b[0],by=cy2+Math.sin(b[1])*r*b[0];c.fillStyle="rgba(120,240,180,"+(0.35+0.4*Math.sin(t*3+b[1]))+")";c.fillRect(bx-1,by-1,2,2);});c.restore();});}
  /* No sweep, no contacts, and a red cross where the trace should be. A radar
     that is simply not animating looks like a radar with nothing on it, which
     is a calm reading of a dead room; the cross is the difference between "no
     traffic" and "no link". */
  if(off){S.strokeStyle="rgba(255,70,58,0.45)";S.lineWidth=2;
    S.beginPath();S.moveTo(cx2-r*0.5,cy2-r*0.5);S.lineTo(cx2+r*0.5,cy2+r*0.5);
    S.moveTo(cx2+r*0.5,cy2-r*0.5);S.lineTo(cx2-r*0.5,cy2+r*0.5);S.stroke();}
  S.strokeStyle="#2a3038";S.lineWidth=2;S.beginPath();S.arc(cx2,cy2,r,0,7);S.stroke();
}
// Follows the radar down; the two of them are one instrument bank now.
function switchboard(t,st){
  var x=756,y=448,w=54,h=42,off=st==="offline";
  wallShadow(x,y,w,h);
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#1a2230","#0c1018","#2a3648");
  for(var r=0;r<3;r++)for(var c=0;c<5;c++){var on=!off&&((r*5+c+Math.floor(t*2))%3===0);S.fillStyle=on?"rgba(95,206,155,0.9)":"#22303e";S.fillRect(x+6+c*9,y+7+r*11,5,5);if(on){G.fillStyle="rgba(95,206,155,0.7)";G.fillRect(x+6+c*9,y+7+r*11,5,5);}}
}
/* A live call. The phone bank was two dark handsets in a box — furniture in the
   one room whose entire job is routing things to people. One line now rings:
   a lit lamp on the left handset with an expanding ring, which is the only
   event-shaped thing in the dispatch room and reads instantly as "someone is
   trying to reach this desk". Silent when the box is. */
function phoneBank(x,t,st){var y=612-30,live=st&&st!=="offline";
  plate(S,[[x,y],[x+40,y],[x+40,y+30],[x,y+30]],"#1a2230","#0c1018","#2a3648");
  for(var i=0;i<2;i++){S.fillStyle="#0e1620";S.fillRect(x+5+i*20,y+5,14,10);S.fillStyle="#3a4656";S.fillRect(x+7+i*20,y+7,10,2);}
  if(live){var rp2=(t*1.4)%1, on2=rp2<0.5?1:0.15;
    emit(function(c){c.fillStyle="rgba(247,189,78,"+(0.85*on2)+")";c.fillRect(x+9,y+18,6,3);
      c.save();c.globalCompositeOperation="lighter";
      c.strokeStyle="rgba(247,189,78,"+(0.4*(1-rp2))+")";c.lineWidth=1.4;
      c.beginPath();c.arc(x+12,y+19,4+16*rp2,0,7);c.stroke();c.restore();});}
  contactShadow(x+20,612,40);}

/* ===================== CONFERENCE CELL (god-view webcam tile) =====================
   The cell used to be a camera pointed at the whole room — the real renderer,
   borrowed through borrowRoom, cropped to a diorama. That kept the art honest,
   and it kept the subject small: at 336px wide the unit an operator is meant
   to recognise was a hundred-odd pixels in a frame that spent the rest of
   itself on furniture. The fleet view's job is "who is here and how are they",
   and a row of establishing shots answers it the long way round.

   So the cell is now a VIDEO CALL TILE. Each unit faces the camera in
   close-up — the fleet view reads as a conference call with the roster — over
   a static, defocused backdrop in its room's colour. Three layers, three
   different lifetimes:

     backdrop  — static per role+size, blur baked in, rendered once ever.
                 No animation by design: it is depth of field, not a scene.
     portrait  — buildRobo cropped to head-and-shoulders, built ONCE per
                 (unit, state, size) at a canonical per-unit time and cached
                 as a deterministic still. The still never advances: sampling
                 smooth positional motion at seconds-scale cadence reads as a
                 broken renderer, not as a laggy webcam (#226). The life the
                 cadence was meant to fake lives in COMPOSITE TIME instead —
                 the blit bobs the still sub-pixel per frame, and the feed
                 fiction is carried by an explicit glitch grammar (still
                 swaps and rare beats), the way real degraded video shows
                 lag: artifacts over continuous motion, never teleports.
     overlays  — AR-style telemetry drawn crisp every frame: state, uptime,
                 idle time over the last 24h, queue, a heartbeat trace, the
                 current session timer. These are the facts, so they never
                 wait on the portrait. */
var CAMREF={W:480,H:300};   // reference tile — renderMini and the whiteboard scale off it

/* ---- static role backdrop --------------------------------------------------
   Drawn sharp into a margin-padded scratch canvas, then blitted once through a
   blur filter, so the cache holds finished pixels and the per-frame cost is a
   single drawImage. The margin exists because a blur pulls transparency in
   from the canvas edge; padding and cropping it off keeps the borders solid. */
var camBGs={};
function camBG(role,pw,ph){
  var key=role+"|"+pw+"x"+ph, e=camBGs[key];
  if(e)return e;
  var M=Math.round(pw*0.06);
  var tw=pw+M*2, th=ph+M*2;
  var tmp=oc(tw,th), c=tmp.getContext("2d");
  var P=role==="builder" ?{hi:[74,50,27], mid:[40,28,17], lo:[16,11,8],  g:[255,170,90]}
       :role==="reviewer"?{hi:[32,60,90], mid:[20,38,58], lo:[8,15,26],  g:[110,190,255]}
       :                  {hi:[64,47,98], mid:[39,30,64], lo:[15,12,27], g:[178,140,255]};
  var g=c.createLinearGradient(0,0,0,th);
  g.addColorStop(0,rgba(P.hi[0],P.hi[1],P.hi[2],1));
  g.addColorStop(0.55,rgba(P.mid[0],P.mid[1],P.mid[2],1));
  g.addColorStop(1,rgba(P.lo[0],P.lo[1],P.lo[2],1));
  c.fillStyle=g;c.fillRect(0,0,tw,th);
  /* Out-of-focus room shapes: a wall seam, two rack silhouettes, a few bokeh
     lights in the role colour. Deliberately vague — after the blur they are
     depth cues, not props. */
  c.fillStyle="rgba(0,0,0,0.30)";c.fillRect(0,th*0.72,tw,th*0.28);
  c.fillStyle=rgba(P.hi[0],P.hi[1],P.hi[2],0.5);c.fillRect(tw*0.06,th*0.16,tw*0.10,th*0.56);
  c.fillStyle="rgba(0,0,0,0.28)";c.fillRect(tw*0.80,th*0.10,tw*0.13,th*0.62);
  c.fillStyle="rgba(0,0,0,0.20)";c.fillRect(tw*0.30,th*0.24,tw*0.05,th*0.48);
  var bok=[[0.16,0.22,0.028,0.55],[0.86,0.18,0.022,0.5],[0.70,0.30,0.016,0.4],[0.25,0.34,0.014,0.35]];
  for(var b=0;b<bok.length;b++){var bk=bok[b];
    var rg2=c.createRadialGradient(tw*bk[0],th*bk[1],1,tw*bk[0],th*bk[1],tw*bk[2]);
    rg2.addColorStop(0,rgba(P.g[0],P.g[1],P.g[2],bk[3]));rg2.addColorStop(1,rgba(P.g[0],P.g[1],P.g[2],0));
    c.fillStyle=rg2;c.beginPath();c.arc(tw*bk[0],th*bk[1],tw*bk[2],0,7);c.fill();}
  var cv=oc(pw,ph), o=cv.getContext("2d");
  o.filter="blur("+Math.max(4,Math.round(pw*0.014))+"px)";
  o.drawImage(tmp,-M,-M);
  o.filter="none";
  /* The soft key the subject stands in, and a baked vignette — camera facts,
     not scene effects, so they live in the cache too. */
  var kg=o.createRadialGradient(pw*0.5,ph*0.34,ph*0.10,pw*0.5,ph*0.55,ph*0.85);
  kg.addColorStop(0,rgba(P.g[0],P.g[1],P.g[2],0.10));kg.addColorStop(1,"rgba(0,0,0,0)");
  o.fillStyle=kg;o.fillRect(0,0,pw,ph);
  var vg=o.createRadialGradient(pw*0.5,ph*0.48,ph*0.45,pw*0.5,ph*0.52,ph*1.05);
  vg.addColorStop(0,"rgba(0,0,0,0)");vg.addColorStop(1,"rgba(0,0,0,0.55)");
  o.fillStyle=vg;o.fillRect(0,0,pw,ph);
  o.globalAlpha=0.05;o.fillStyle="#000";
  for(var sl=0;sl<ph;sl+=3)o.fillRect(0,sl,pw,1);
  o.globalAlpha=1;
  camBGs[key]=cv;return cv;
}

/* ---- the portrait ----------------------------------------------------------
   buildRobo, not borrowRoom: the tile needs the unit, not the hall, so the
   still costs a sprite build instead of a full room render. A still is a PURE
   FUNCTION of (box, agent, room, state, size): it is built at a canonical
   per-unit time — strPhase(box), constant for the life of the box — so every
   time-driven term in the builders (breath, sway, bob, glow pulses) freezes
   at a stable, per-unit phase, and a cache hit is always exact. Rebuilds
   happen on cache miss only: first sight, state change, resize. Framing
   hangs off the one face anchor every vendor already reports (`hy`, the
   visor line), with a per-vendor crop width because a spider and a humanoid
   do not wear their shoulders at the same span. */
/* w — crop width in robo px (smaller = closer); fy — where the face line
   sits down the frame; dy — bias in robo px for vendors whose `hy` is not
   their eye line (kimi reports the cowl, a head lower than its optics).
   ba/bf — composite-time bob amplitude (sprite px) and frequency, seeded
   from each sprite's own baked sine so the tile moves the way the room
   shows the same unit moving; bx/bxf — grok's sway x-component. Applied at
   blit time in drawCamCell, scaled by screen-px-per-sprite-px, so screen
   motion is uniform across vendors regardless of crop zoom. */
var CAMFRAME={claude:{w:250,dy:0,fy:0.40,ba:2.0,bf:1.4},
              codex:{w:260,dy:14,fy:0.46,ba:1.4,bf:1.5},
              grok:{w:206,dy:-2,fy:0.36,ba:1.6,bf:1.7,bx:0.8,bxf:1.3},
              kimi:{w:330,dy:-38,fy:0.42,ba:2.2,bf:1.6}};
function mnow(){return (window.performance&&performance.now)?performance.now():0;}
var camStills={}, camFills=0, camCost=0, camSwaps={}, camShown={}, camBuiltAt=[], camVis=0;
/* CAM_BUDGET is a builds-per-frame ration for miss storms (resize,
   scroll-reveal) — steady state builds nothing. It is 1 because a
   supersampled build costs ~45-85ms (camstats().buildEmaMs, measured
   headless): at 2, a storm frame carried two of those. One per frame keeps
   the worst storm frame at one build; the storm lasts longer instead of
   cutting deeper, and the backdrop shows through the extra frames. */
var CAM_KEEP=64, CAM_BUDGET=1;
function camPrune(){
  /* The floor may show more than CAM_KEEP tiles (4 columns on a tall enough
     wall display). A fixed cap below the visible count would evict a VISIBLE
     still on every miss and turn the cache into a rolling 1-build-per-frame
     stampede — so the cap follows the roster the floor actually draws. */
  var keep=Math.max(CAM_KEEP,camVis+8);
  var ks=Object.keys(camStills);if(ks.length<keep)return;
  ks.sort(function(a,b){return camStills[a].at-camStills[b].at;});
  for(var i=0;i<ks.length-keep+1;i++)delete camStills[ks[i]];
}
function camStill(t,u,pw,ph){
  var box=UNITID(u);
  var key=box+"|"+u.agent+"|"+u.room+"|"+u.state+"|"+pw+"x"+ph;
  var e=camStills[key];
  if(e&&e.ok){
    e.at=mnow();
    /* A cache hit that CHANGES which still this box shows — a state flip
       back to a still that is already warm, a resize to a cached size — is
       still a feed swap. Without this, only cache-MISS swaps glitched, and a
       warm working-idle flip was an instant unglitched teleport: the exact
       artifact this redesign exists to kill. Dev renders (camFills forced
       negative) record nothing, so goldens stay pure. */
    if(camFills>=0&&camShown[box]!==key){camShown[box]=key;camSwaps[box]=t;}
    return e;
  }
  if(camFills>=CAM_BUDGET)return null;
  camFills++;
  if(!e){camPrune();e=camStills[key]={cv:oc(pw,ph),at:mnow(),ok:0};}
  var t0=mnow(), sa=AGENT, ss=STATE, sbp=beaconPulse;
  /* The canonical build time. Also pin beaconPulse — it is written by the
     ROOM view's beacon each frame, so an offline kimi still would otherwise
     depend on which console the operator last visited. */
  var tCanon=strPhase(box);
  var f=CAMFRAME[u.agent]||CAMFRAME.claude;
  /* The build lands on the supersampled portrait trio, at the density THIS
     crop needs to hit ~1:1 device pixels — resolution parity across vendors
     regardless of crop width. Same save/swap/restore pattern as AGENT/STATE —
     but in a try/finally: if a build ever throws (a null context under
     canvas-memory pressure, a context loss), the room renderer must not be
     left drawing on the portrait trio at SS!=1. That corruption would
     outlive the frame that caused it; the old wall-clock code risked only a
     one-frame AGENT/STATE mislabel. */
  ensurePortraitTrio();
  var sRo=robo,sRB=RB,sEm=remit,sRE=RE,sRi=rrim,sRR=RR;
  try{
  beaconPulse=0.65;
  AGENT=u.agent;STATE=u.state;
  robo=roboP;RB=RBP;remit=remitP;RE=REP;rrim=rrimP;RR=RRP;
  SS=Math.max(1,Math.min(SS_MAX,pw/f.w));
  var info=buildRobo(tCanon,u.state);
  /* The role's key light lands on the unit, same rule as drawRobot's L17 tint:
     a sprite that keeps studio-neutral colour in an amber room is a paste-up. */
  var off=u.state==="offline";
  var kt=off?[96,110,136]:u.room==="builder"?[255,201,135]:u.room==="reviewer"?[150,196,245]:[176,150,240];
  RB.save();RB.setTransform(SS,0,0,SS,0,0);RB.globalCompositeOperation="source-atop";
  var ktg=RB.createLinearGradient(0,60,0,RH*0.9);
  ktg.addColorStop(0,rgba(kt[0],kt[1],kt[2],off?0.10:0.13));
  ktg.addColorStop(1,rgba(kt[0],kt[1],kt[2],0));
  RB.fillStyle=ktg;RB.fillRect(0,0,RW,RH);RB.restore();
  /* Static per-box framing jitter — no two operators mount a camera at the
     same angle, and identical framing is what makes a grid read as clones. */
  var jx=(strPhase(box)/6.283-0.5)*16, jy=(strPhase(box+"y")/6.283-0.5)*10;
  var sw=f.w, sh=sw*(ph/pw);
  var sx=Math.max(0,Math.min(RW-sw,260+jx-sw/2));
  /* The camera is MOUNTED. hy rides the sprite's own idle motion, but the
     sprite is now built at tCanon, so hy is the same number every build of
     this key — the mount is deterministic without the first-frame lock the
     wall-clock builds needed. */
  var sy=info.hy+f.dy-sh*f.fy+jy;
  var c=e.cv.getContext("2d");
  c.setTransform(1,0,0,1,0,0);c.globalAlpha=1;c.globalCompositeOperation="source-over";c.filter="none";
  c.imageSmoothingEnabled=true;c.imageSmoothingQuality="high";
  c.clearRect(0,0,pw,ph);
  if(off)c.filter="saturate(0.45) brightness(0.88)";
  c.drawImage(robo,sx*SS,sy*SS,sw*SS,sh*SS,0,0,pw,ph);
  c.filter="none";
  c.globalCompositeOperation="lighter";
  c.globalAlpha=off?0.4:0.9;c.drawImage(rrim,sx*SS,sy*SS,sw*SS,sh*SS,0,0,pw,ph);
  /* The emissive pass, blurred like the room compositor's glow buffer but
     scaled to portrait zoom. Two taps, not three: the third radius at this
     size is a wash. */
  var bl=Math.max(2,Math.round(pw/90));
  c.globalAlpha=0.55;c.filter="blur("+bl+"px)";c.drawImage(remit,sx*SS,sy*SS,sw*SS,sh*SS,0,0,pw,ph);
  c.globalAlpha=0.45;c.filter="blur("+bl*3+"px)";c.drawImage(remit,sx*SS,sy*SS,sw*SS,sh*SS,0,0,pw,ph);
  c.globalAlpha=off?0.5:0.9;c.filter="none";c.drawImage(remit,sx*SS,sy*SS,sw*SS,sh*SS,0,0,pw,ph);
  c.globalCompositeOperation="source-over";c.globalAlpha=1;
  }finally{
  robo=sRo;RB=sRB;remit=sEm;RE=sRE;rrim=sRi;RR=sRR;SS=1;
  AGENT=sa;STATE=ss;beaconPulse=sbp;
  }
  e.ok=1;e.at=mnow();
  /* A landed build is a feed swap — drawCamCell performs a glitch over it.
     The dev path (renderMini, camFills forced negative) records none — not
     in the ledger, not in the stats — so a golden render stays a pure
     function of its arguments and camstats describes the LIVE pipeline only
     (its contract: buildsLastSec reads 0 on a stable roster). */
  if(camFills>0){
    camShown[box]=key;camSwaps[box]=t;
    for(var sk in camSwaps)if(t-camSwaps[sk]>2)delete camSwaps[sk];
    var d=mnow()-t0;camCost=camCost?camCost*0.6+d*0.4:d;
    camBuiltAt.push(mnow());if(camBuiltAt.length>240)camBuiltAt.splice(0,120);
  }
  return e;
}

/* ---- AR widgets ------------------------------------------------------------
   One beat of an EKG, p in [0,1): flat baseline, P bump, QRS spike, T wave.
   Positive is DOWN (canvas y). */
function ekgY(p){
  if(p<0.06)return 0;
  if(p<0.13)return -0.14*Math.sin((p-0.06)/0.07*Math.PI);
  if(p<0.16)return 0.20*((p-0.13)/0.03);
  if(p<0.20)return 0.20-1.20*((p-0.16)/0.04);
  if(p<0.24)return -1.0+1.34*((p-0.20)/0.04);
  if(p<0.27)return 0.34-0.34*((p-0.24)/0.03);
  if(p<0.34)return 0;
  if(p<0.48)return -0.24*Math.sin((p-0.34)/0.14*Math.PI);
  return 0;
}
function drawEKG(x,y,w,h,t,rate,col,label){
  var yb=y+h*0.62, amp=h*0.52;
  X.save();
  X.strokeStyle="rgba(255,255,255,0.07)";X.lineWidth=1;
  X.beginPath();X.moveTo(x,yb);X.lineTo(x+w,yb);X.stroke();
  if(rate<=0){ // flatline: the trace is the fact, so a dead unit draws a dead trace
    X.strokeStyle=col;X.globalAlpha=0.75;X.lineWidth=1.4;
    X.beginPath();X.moveTo(x,yb);X.lineTo(x+w,yb);X.stroke();X.globalAlpha=1;
  }else{
    var lg=X.createLinearGradient(x,0,x+w,0);
    lg.addColorStop(0,"rgba(0,0,0,0)");lg.addColorStop(0.35,col);lg.addColorStop(1,col);
    X.strokeStyle=lg;X.lineWidth=1.6;X.lineJoin="round";
    X.beginPath();
    for(var i=0;i<=w;i+=2){
      var p=(t*rate-(w-i)*0.006)%1;if(p<0)p+=1;
      var py=yb+ekgY(p)*amp;
      if(i)X.lineTo(x+i,py);else X.moveTo(x+i,py);
    }
    X.stroke();
    var pl2=(t*rate)%1, ly=yb+ekgY(pl2)*amp;
    X.fillStyle="#fff";X.globalAlpha=0.9;X.fillRect(x+w-1.5,ly-1.5,3,3);X.globalAlpha=1;
  }
  X.font="700 8px ui-monospace,monospace";X.fillStyle=col;X.textAlign="right";
  X.fillText(label,x+w,y-2);X.textAlign="left";
  X.restore();
}
/* Idle over the trailing 24h, from the same session ledger the console shows.
   ago is minutes; durations are seconds; the window shrinks to the uptime so
   a box hired an hour ago is idle out of ONE hour, not out of a day it has
   not lived. null when the unit has reported nothing to count. */
function idle24(d){
  var upS=(d.up?d.up.h*3600+d.up.m*60:0);
  if(!upS&&!(d.sessions&&d.sessions.length))return null;
  var busy=0;
  (d.sessions||[]).forEach(function(s){if((s.ago||0)<=1440)busy+=Math.min(s.dur||0,86400);});
  if(d.cur&&d.cur.start)busy+=Math.max(0,Math.floor(Date.now()/1000)-d.cur.start);
  var win=Math.min(86400,upS||86400);
  return Math.max(0,win-busy);
}

/* God-view headroom is deliberately smaller than boxVitalsRows: the tile has
   room for the two figures an operator scans across the fleet, while the
   console keeps the full measured record. Current/max uses the existing pair
   and derives no policy — thresholds and findings stay box-side. */
function camHeadroomRows(v){
  var f=v&&v.fields?v.fields:{};
  function gib(m){
    var n=Number(m)/1024;
    if(!Number.isFinite(n)||n<0)return null;
    return (n<10?n.toFixed(1):String(Math.round(n))).replace(/\.0$/,"");
  }
  function pair(cur,total){
    var c=gib(cur),t=gib(total);
    return c===null||t===null?"—":c+"/"+t+"G";
  }
  var mem="—",disk="—";
  if(f.mem_total_mb!==undefined&&f.mem_avail_mb!==undefined){
    var mt=Number(f.mem_total_mb),ma=Number(f.mem_avail_mb);
    if(Number.isFinite(mt)&&Number.isFinite(ma)&&mt>=ma)
      mem=pair(mt-ma,mt);
  }
  if(f.disk_total_mb!==undefined&&f.disk_used_mb!==undefined)
    disk=pair(f.disk_used_mb,f.disk_total_mb);
  return [["MEM",mem],["DISK",disk]];
}

/* One tile of the call. Chrome is drawn inside the feed like a heads-up
   overlay burned into the stream, because that is what an AR readout is:
   the video is the whole card, and the facts sit on top of it. */
function drawCamCell(t,x,y,w,h,unit){
  var off=unit.state==="offline", work=unit.state==="working", suppressed=unit.state==="suppressed";
  var box=UNITID(unit), d=dataOf(box,unit.room), vc=VENDORCOL(unit.agent);
  var bp=strPhase(box);
  X.save();X.textBaseline="alphabetic";X.textAlign="left";
  X.fillStyle="rgba(0,0,0,0.55)";rr(X,x-3,y-3,w+6,h+6,14);X.fill();
  X.fillStyle="#04070d";rr(X,x,y,w,h,12);X.fill();
  X.save();rr(X,x+1,y+1,w-2,h-2,11);X.clip();
  var pw=Math.max(1,Math.round((w-2)*dpr)), ph=Math.max(1,Math.round((h-2)*dpr));
  X.drawImage(camBG(unit.room,pw,ph),x+1,y+1,w-2,h-2);
  var still=camStill(t,unit,pw,ph);
  if(still&&still.ok){
    /* Composite-time motion: the still is frozen, so the LIFE is applied at
       blit time — a sub-pixel bob in each sprite's own rhythm, phase-offset
       per box so tiles never sync, amplitude scaled to screen px so every
       vendor moves the same amount regardless of crop zoom. One translated
       drawImage per frame: 60fps smoothness at negligible cost. The 1-2px
       gap it opens at the frame edge shows the defocused backdrop — the
       subject moves inside a mounted camera's frame, which is the webcam
       grammar the cadence never delivered. Dead is still; reduced is still. */
    var fb=CAMFRAME[unit.agent]||CAMFRAME.claude, bsc=(w-2)/fb.w;
    var by=(off||reduced)?0:fb.ba*bsc*Math.sin(t*fb.bf+bp);
    var bx3=(off||reduced||!fb.bx)?0:fb.bx*bsc*Math.sin(t*(fb.bxf||1.3)+bp*1.7);
    X.drawImage(still.cv,x+1+bx3,y+1+by,w-2,h-2);
  }
  /* Live sensor grain — the one per-frame texture, and the base coat of the
     feed fiction under the glitch grammar. */
  X.save();X.globalAlpha=off?0.07:0.04;X.globalCompositeOperation="overlay";
  var nx=-(((reduced?bp:t)*61)%40),ny=-(((reduced?bp:t)*47)%40);
  for(var gx=nx;gx<w;gx+=220)for(var gy=ny;gy<h;gy+=220)X.drawImage(noise,x+gx,y+gy);
  X.restore();
  /* Glitch grammar — the feed fiction the refresh cadence used to fake, done
     the way real degraded video does it: the subject's motion is continuous
     and the LAG is an artifact the tile performs. Two triggers: a landed
     still swap (state change, resize — the feed "re-syncs"), and a rare
     per-tile beat, phase-hashed so tiles never fire together. Three effects
     in the vocabulary the offline roll established: a displaced slice, a
     chroma split, a block smear. All of it a pure function of (t, box), so
     dev renders reproduce; none of it under reduced motion; offline tiles
     keep their own roll instead. */
  if(!reduced&&!off&&still&&still.ok){
    var swT=camSwaps[box], gk=-1, gs=0;
    if(swT!==undefined&&t-swT>=0&&t-swT<0.06){gk=0;gs=1;}
    else{
      var gP=7+(bp/6.283)*5, gph=(t+bp*7)%gP;
      if(gph<0.08){gk=Math.floor((t+bp*7)/gP)%3;gs=1-gph/0.08;}
    }
    if(gk===0){ // displaced slices, the roll's own move at feed strength
      for(var gi=0;gi<3;gi++){
        var gsy=y+8+((bp*151+gi*67+Math.floor(t*30)*13)%(h-24));
        var gdx=(((bp*89+gi*41)%13)-6)*gs;
        X.save();X.globalAlpha=0.55*gs;
        X.drawImage(X.canvas,(x+1)*dpr,gsy*dpr,(w-2)*dpr,3*dpr,x+1+gdx,gsy,w-2,3);
        X.restore();
      }
    }else if(gk===1){ // one-frame chroma split: the still ghosted either side
      /* At the bob's own offset — a ghost that ignores the bob would jump
         vertically against its subject, breaking the grammar's one rule:
         the subject's motion is continuous, only artifacts flash. */
      X.save();X.globalCompositeOperation="lighter";X.globalAlpha=0.16*gs;
      X.drawImage(still.cv,x+1+bx3-3*gs,y+1+by,w-2,h-2);
      X.drawImage(still.cv,x+1+bx3+3*gs,y+1+by,w-2,h-2);
      X.restore();
    }else if(gk===2){ // block smear: one region of the feed re-sent too big
      var smw=w*0.26, smh=h*0.15;
      var smx=x+1+((bp*97)%(w-smw-2)), smy=y+1+8+((bp*53)%(h-smh-16));
      X.save();X.globalAlpha=0.6*gs;
      X.drawImage(X.canvas,smx*dpr,smy*dpr,smw*dpr,smh*dpr,
                  smx-smw*0.09,smy-smh*0.09,smw*1.18,smh*1.18);
      X.restore();
    }
  }
  if(off){
    /* A dead feed rolls: one displaced slice wandering the frame, and the
       overlay says why. The portrait underneath is already cold and dark —
       baked into the still — so this is only the motion. */
    var gy2=y+(((reduced?0:t*26)+bp*40)%h);
    X.save();X.globalAlpha=0.5;
    X.drawImage(X.canvas,(x+1)*dpr,gy2*dpr,(w-2)*dpr,4*dpr,x+7,gy2,w-2,4);
    X.fillStyle="rgba(255,81,71,0.05)";X.fillRect(x,y,w,h);
    X.restore();
  }
  // legibility gradient under the lower-third overlays
  var lg=X.createLinearGradient(0,y+h-58,0,y+h);
  lg.addColorStop(0,"rgba(2,4,8,0)");lg.addColorStop(1,"rgba(2,4,8,0.78)");
  X.fillStyle=lg;X.fillRect(x+1,y+h-58,w-2,57);

  /* ---- AR overlay layer, crisp every frame ---- */
  var pad=10;
  X.strokeStyle=hexA(vc,off?0.35:0.7);X.lineWidth=1.5;var T=13;
  [[x+pad,y+pad,1,1],[x+w-pad,y+pad,-1,1],[x+pad,y+h-pad,1,-1],[x+w-pad,y+h-pad,-1,-1]].forEach(function(k){
    X.beginPath();X.moveTo(k[0],k[1]+T*k[3]);X.lineTo(k[0],k[1]);X.lineTo(k[0]+T*k[2],k[1]);X.stroke();});
  X.textBaseline="middle";
  // state, top-left — REC language when a session is actually open
  var sx2=x+pad+7, sy2=y+pad+9;
  X.font="700 10px ui-monospace,monospace";
  if(work){
    var rp=0.55+0.45*Math.sin(t*4+bp);
    X.fillStyle="rgba(255,60,50,"+rp+")";X.beginPath();X.arc(sx2,sy2,3.5,0,7);X.fill();
    X.fillStyle="#ffd9d5";X.fillText("REC",sx2+8,sy2+0.5);
    X.fillStyle="#f7bd4e";X.fillText(unit.room==="builder"?"BUILDING":unit.room==="reviewer"?"REVIEWING":"DISPATCH",sx2+34,sy2+0.5);
    if(d.cur&&d.cur.start){
      X.font="9px ui-monospace,monospace";X.fillStyle="rgba(255,217,213,0.8)";
      X.fillText(fmtDur(Math.floor(Date.now()/1000)-d.cur.start),sx2+8,sy2+13);
    }
  }else if(off){
    X.fillStyle="#ff5147";X.fillText("✕ FEED DOWN",sx2-3,sy2+0.5);
  }else if(suppressed){
    X.fillStyle="#f28b54";X.beginPath();X.arc(sx2,sy2,3,0,7);X.fill();
    X.fillStyle="#ffb184";X.fillText("SUPPRESSED",sx2+8,sy2+0.5);
  }else{
    X.fillStyle="#5fce9b";X.beginPath();X.arc(sx2,sy2,3,0,7);X.fill();
    X.fillStyle="#8fe8bc";X.fillText("STANDBY",sx2+8,sy2+0.5);
  }
  /* telemetry block, top-right: the AR readout this view exists for.
     A glass panel, not bare text — at tile size the facts have to win
     against whatever the portrait is doing behind them. */
  var idl=idle24(d);
  var last=d.sessions&&d.sessions[0];
  var rows=[["UPTIME",(d.up&&(d.up.h||d.up.m))?d.up.h+"h"+pad2(d.up.m)+"m":"—"],
            ["IDLE·24H",idl===null?"—":(idl<60?"0m":fmtDur(idl))],
            ["QUEUE",off?"—":String(d.queue.length)],
            ["LAST",last?(last.ago>=60?Math.floor(last.ago/60)+"h"+pad2(last.ago%60)+"m ago":last.ago+"m ago"):"—"],
            /* The newest session's peak RSS (#473): the box that thrashed for
               twelve minutes looked, on this panel, exactly like the box
               beside it. It sits under LAST because it describes that same
               session and nothing wider. */
            ["PEAK",last?fmtKiB(last.peak):"—"]].concat(camHeadroomRows(d.vitals));
  var tpw=118,tph=rows.length*14+22,tpx=x+w-pad-4-tpw,tpy=y+pad+2;
  X.fillStyle="rgba(4,8,14,0.55)";rr(X,tpx,tpy,tpw,tph,4);X.fill();
  X.strokeStyle=hexA(vc,0.30);X.lineWidth=1;rr(X,tpx,tpy,tpw,tph,4);X.stroke();
  X.fillStyle=hexA(vc,0.8);X.fillRect(tpx+tpw-1.5,tpy+3,1.5,tph-6);
  var ty=tpy+10;
  rows.forEach(function(r2){
    X.textAlign="right";
    X.font="700 10px ui-monospace,monospace";
    X.fillStyle="#d5e6f6";X.fillText(r2[1],tpx+tpw-8,ty);
    X.font="700 7px ui-monospace,monospace";
    X.textAlign="left";X.fillStyle=hexA(vc,0.75);X.fillText(r2[0],tpx+7,ty);
    ty+=14;
  });
  // signal, bottom row of the panel — live ping tier, or steady bars in demo
  var bars=off?0:(d.ping?(d.ping.ok?4:Math.max(0,3-d.ping.fails)):3+(bp>4?1:0));
  X.font="700 7px ui-monospace,monospace";X.fillStyle=hexA(vc,0.75);X.fillText("SIGNAL",tpx+7,ty);
  for(var sb=0;sb<4;sb++){
    var bh=3+sb*2.6, on=sb<bars;
    X.fillStyle=on?(bars>=3?"rgba(95,206,155,0.95)":"rgba(247,189,78,0.95)"):"rgba(255,255,255,0.14)";
    X.fillRect(tpx+tpw-8-(3-sb)*6,ty+4-bh,4,bh);
  }
  X.textAlign="left";
  // lower third: identity plate, voice bars, heartbeat
  var ny2=y+h-pad-10;
  X.fillStyle=vc;X.beginPath();X.arc(x+pad+7,ny2-9,3.5,0,7);X.fill();
  X.font="700 12px ui-monospace,monospace";X.fillStyle="#e8f0f8";
  X.fillText(box,x+pad+16,ny2-9);
  var nw=X.measureText(box).width;
  X.font="9px ui-monospace,monospace";X.fillStyle="rgba(160,190,220,0.65)";
  X.fillText(unit.agent+" · "+ROLEWORD2(unit.room),x+pad+16,ny2+4);
  // voice-activity meter beside the name — the conference tell for "talking"
  var vx2=x+pad+22+nw;
  for(var vb=0;vb<4;vb++){
    /* Working talks; idle is a muted mic that still hears the room — a soft
       swell every few seconds — and a dead feed hears nothing at all. */
    var lvl=work?(0.25+0.75*Math.abs(Math.sin(t*6.3+vb*1.7+bp)))
               :off?0
               :(0.06+0.5*Math.pow(Math.max(0,Math.sin(t*0.9+bp+vb*0.4)),8));
    X.fillStyle=work?hexA(vc,0.85):"rgba(190,215,235,"+(off?0.10:0.30)+")";
    var vh3=2+9*lvl;
    X.fillRect(vx2+vb*4.5,ny2-7-vh3/2,2.6,vh3);
  }
  /* Live caption, centre-bottom: what this unit is saying right now — the
     open session's work item, typed like speech-to-text. The one fact the
     tile was still missing: QUEUE says how much is waiting, the caption says
     what is actually being worked. */
  if(work&&d.cur&&d.cur.key){
    var cap=(d.kind==="build"?"building ":d.kind==="review"?"reviewing ":"dispatching ")+d.cur.key;
    X.font="10px ui-monospace,monospace";
    var cyc=cap.length+26, nch=Math.min(cap.length,Math.floor(((t*16+bp*10)%cyc)));
    var shown=cap.slice(0,nch), cw2=X.measureText(cap).width;
    if(cw2<w-2*pad-40){
      var cx2=x+w/2, cy2=y+h-pad-36;
      X.fillStyle="rgba(4,8,14,0.66)";rr(X,cx2-cw2/2-10,cy2-9,cw2+20,18,4);X.fill();
      X.textAlign="center";
      X.fillStyle="rgba(200,225,245,0.92)";
      X.fillText(shown+(Math.sin(t*9)>0&&nch<cap.length?"▌":""),cx2,cy2);
      X.textAlign="left";
    }
  }
  // heartbeat, bottom-right: rate follows state, flatlines with the box
  var hr=off?0:work?(1.35+0.25*Math.sin(bp)):0.72;
  var hw=Math.min(140,w*0.32);
  drawEKG(x+w-pad-6-hw,y+h-pad-26,hw,24,t+bp,hr,
          off?"rgba(255,81,71,0.85)":work?"rgba(120,225,255,0.9)":"rgba(95,206,155,0.8)",
          off?"— BPM":Math.round(hr*60+2*Math.sin(t*0.7+bp))+" BPM");
  if(off){
    X.font="700 11px ui-monospace,monospace";X.textAlign="center";
    var slw=X.measureText("SIGNAL LOST — RECONNECTING").width;
    X.fillStyle="rgba(8,3,3,0.72)";rr(X,x+(w-slw)/2-10,y+h*0.5-11,slw+20,22,4);X.fill();
    X.fillStyle="rgba(255,124,114,"+(reduced?0.85:(0.75+0.25*Math.sin(t*3)))+")";
    X.fillText("SIGNAL LOST — RECONNECTING",x+w/2,y+h*0.5);
    X.textAlign="left";
  }
  X.restore(); // clip
  // frame: a working unit wears the speaking ring, a dead one pulses red
  if(work){
    X.strokeStyle=hexA(vc,0.45+0.30*Math.sin(t*3+bp));X.lineWidth=2;
    rr(X,x+1,y+1,w-2,h-2,11);X.stroke();
  }else{
    X.strokeStyle=off?"rgba(255,81,71,"+(0.35+0.25*Math.abs(Math.sin(t*3)))+")":"rgba(255,255,255,0.10)";
    X.lineWidth=1.5;rr(X,x+1,y+1,w-2,h-2,11);X.stroke();
  }
  X.restore();X.textBaseline="alphabetic";
}
function ROLEWORD2(r){return r==="builder"?"builder":r==="reviewer"?"reviewer":"triage";}

/* ===================== GOD-VIEW FLOOR (the call grid) ===================== */
var VIEW="floor";
/* The page has two modes and decides between them at load, by asking the
   collector for a snapshot:

     served by `crew floor`  → /api/fleet answers → LIVE, real telemetry, real
                               operator controls (crew reads and drives every
                               box from the host over `box exec`)
     opened as a local file  → the fetch fails → DEMO, the placeholder fleet
                               below, controls shown but disabled

   That keeps the property the prototype was built on — one self-contained
   index.html you can just open — while making the served copy a real console.
   Nothing below is a fallback for missing live fields: a served page renders
   only what the boxes actually reported. */
var LIVE=false;
var ROSTER=[
  {agent:"claude",room:"triage",  state:"working"},
  {agent:"claude",room:"builder", state:"working"},
  {agent:"claude",room:"reviewer",state:"idle"},
  {agent:"codex", room:"builder", state:"working"},
  {agent:"codex", room:"reviewer",state:"working"},
  {agent:"grok",  room:"reviewer",state:"idle"},
  {agent:"kimi",  room:"reviewer",state:"offline"}
];
/* The grid is a call layout: columns fit the window at a comfortable tile
   width and the OVERFLOW is vertical, because that is the way every
   conference UI and every operator's mouse wheel already scrolls. */
var floorCam=0, floorCamTarget=0, floorDrag=false, floorDragY=0, floorDragCam=0, floorMoved=false, floorMouse={x:-1,y:-1}, floorHits=[];
function floorGrid(){
  /* The byline owns the lane immediately below the fixed fleetbar. Keep the
     first row below that lane too, so solving the DOM collision cannot turn
     into a canvas-on-tile collision. */
  var mX=26, mT=floorHeaderY()+18, gap=20;
  var availW=VW-mX*2;
  var cols=Math.max(1,Math.min(4,Math.round(availW/500)));
  if(ROSTER.length&&ROSTER.length<cols)cols=ROSTER.length;
  var tw=Math.floor((availW-(cols-1)*gap)/cols);
  var th=Math.round(tw*0.60);
  var rows=Math.ceil(Math.max(1,ROSTER.length)/cols);
  return {mX:mX,mT:mT,gap:gap,cols:cols,tw:tw,th:th,rows:rows,
          totalH:mT+rows*th+(rows-1)*gap+170};
}
function drawFloor(t){
  camFills=0;   // portrait refresh budget for THIS frame
  X.setTransform(dpr,0,0,dpr,0,0);X.imageSmoothingEnabled=true;X.textAlign="left";X.globalAlpha=1;X.globalCompositeOperation="source-over";
  X.fillStyle="#03060d";X.fillRect(0,0,VW,VH);
  var vg=X.createRadialGradient(VW/2,VH*0.36,VH*0.15,VW/2,VH*0.5,VH);vg.addColorStop(0,"rgba(20,32,52,0.22)");vg.addColorStop(1,"rgba(0,0,0,0)");X.fillStyle=vg;X.fillRect(0,0,VW,VH);
  X.strokeStyle="rgba(40,60,90,0.05)";X.lineWidth=1;for(var gx=0;gx<VW;gx+=48){X.beginPath();X.moveTo(gx,0);X.lineTo(gx,VH);X.stroke();}for(var gy=0;gy<VH;gy+=48){X.beginPath();X.moveTo(0,gy);X.lineTo(VW,gy);X.stroke();}
  var Gd=floorGrid();
  var camMax=Math.max(0,Gd.totalH-VH);
  if(!floorDrag)floorCam+=(floorCamTarget-floorCam)*0.18;
  floorCam=Math.max(0,Math.min(floorCam,camMax));floorCamTarget=Math.max(0,Math.min(floorCamTarget,camMax));
  floorHits.length=0;
  var vis=0;
  for(var i=0;i<ROSTER.length;i++){var col=i%Gd.cols,row=Math.floor(i/Gd.cols);
    var cx=Gd.mX+col*(Gd.tw+Gd.gap);var cy=Gd.mT+row*(Gd.th+Gd.gap)-floorCam;
    if(cy>-Gd.th-40&&cy<VH+40){
      var u=ROSTER[i],match=matchesFloorFilter(u);
      drawCamCell(t,cx,cy,Gd.tw,Gd.th,u);
      if(!match){X.fillStyle="rgba(3,6,13,0.76)";rr(X,cx,cy,Gd.tw,Gd.th,11);X.fill();}
      /* A STUCK or UNREACHABLE unit must be visible from the god-view. Both
         wear an ordinary state otherwise — stuck reads "working", and a box
         that fails its ping keeps whatever the last evidence poll concluded —
         so the grid showed a calm fleet in exactly the two situations an
         operator is scanning it for. Drawn after the filter scrim, so a
         filtered-out unit does not shout through it. */
      if(match)drawAlertBadge(cx,cy,u,Gd.tw);
      var hov=(floorMouse.x>=cx&&floorMouse.x<=cx+Gd.tw&&floorMouse.y>=cy&&floorMouse.y<=cy+Gd.th);
      if(hov&&match){X.save();X.strokeStyle="rgba(120,205,255,0.85)";X.lineWidth=2;rr(X,cx-2,cy-2,Gd.tw+4,Gd.th+4,13);X.stroke();
        /* Say what the click does. The ring alone marks the tile; nothing on
           it said the whole feed is a door into the unit's console. */
        var hint="OPEN CONSOLE ▸";X.font="700 9px ui-monospace,monospace";
        var hwd=X.measureText(hint).width;
        X.fillStyle="rgba(4,10,18,0.85)";rr(X,cx+(Gd.tw-hwd)/2-9,cy+Gd.th-22,hwd+18,17,4);X.fill();
        X.strokeStyle="rgba(120,205,255,0.5)";X.lineWidth=1;rr(X,cx+(Gd.tw-hwd)/2-9,cy+Gd.th-22,hwd+18,17,4);X.stroke();
        X.fillStyle="#9fdcff";X.textBaseline="middle";X.fillText(hint,cx+(Gd.tw-hwd)/2,cy+Gd.th-13.5);X.textBaseline="alphabetic";
        X.restore();}
      floorHits.push({x:cx,y:cy,w:Gd.tw,h:Gd.th,i:i,match:match});
      vis++;
    }}
  camVis=vis;
  /* The rows scroll under fixed chrome at both ends — ease them out instead
     of letting a feed collide with the fleet bar's chips. */
  var ts=X.createLinearGradient(0,0,0,104);ts.addColorStop(0,"rgba(3,6,13,1)");ts.addColorStop(0.55,"rgba(3,6,13,0.62)");ts.addColorStop(1,"rgba(3,6,13,0)");
  X.fillStyle=ts;X.fillRect(0,0,VW,104);
  var bs=X.createLinearGradient(0,VH-190,0,VH-120);bs.addColorStop(0,"rgba(3,6,13,0)");bs.addColorStop(1,"rgba(3,6,13,0.85)");
  X.fillStyle=bs;X.fillRect(0,VH-190,VW,70);
  if(camMax>0){var tr0=70,tr1=VH-170,trh=tr1-tr0;
    var tl=Math.max(36,trh*(trh/Gd.totalH)),tp=tr0+(floorCam/camMax)*(trh-tl);
    X.fillStyle="rgba(255,255,255,0.08)";X.fillRect(VW-10,tr0,4,trh);
    X.fillStyle="rgba(120,200,255,0.65)";X.fillRect(VW-10,tp,4,tl);}
  var vg2=X.createRadialGradient(VW/2,VH/2,VH*0.42,VW/2,VH/2,VH*0.95);vg2.addColorStop(0,"rgba(0,0,0,0)");vg2.addColorStop(1,"rgba(0,0,0,0.5)");X.fillStyle=vg2;X.fillRect(0,0,VW,VH);
  /* Fixed chrome is painted last so the scrolling floor can never erase it. */
  drawFloorHeader(t);
}
/* alertOf UNIT — the one word this unit needs shouted on the grid, or "".
   Order is severity, not alphabetical: a box that has stopped answering pings
   is a worse fact than a stuck lock, and a stuck lock is worse than a dead
   credential, because each one makes the next impossible to act on.

   UNREACHABLE is the COLLECTOR's verdict, read off `ping.wedged`, never a
   count this page compares itself. It used to be the miss count against a
   constant of this page's own with 3 baked into it, while the collector
   wedges at `CREW_FLOOR_PING_FAILS` —
   2 in this repo's own suite — so the badge and the control that escalates
   on the same fact could disagree, and did (#486). There is deliberately no
   threshold constant left in this file to drift again. */
function alertData(d){
  if(d.ping&&d.ping.wedged)return "UNREACHABLE";
  if(d.lock&&d.lock.stuck)return "STUCK";
  if(d.authfail&&d.authfail.length)return "AUTH";
  if(d.limited)return "LIMITED";
  return "";
}
function alertOf(u){
  if(!LIVE)return "";
  return alertData(dataOf(UNITID(u),u.room));
}
/* stoppedWord DATA — why this box is not ticking, or "" if nobody stopped it.
   SILENT is an alarm: "this box should be ticking and is not". #189 taught the
   COLLECTOR to rank paused, disarmed and silent apart, and it does — but it
   gives all three the same state:"offline" (server/floor.py), deliberately,
   because they share a colour. The page then keyed every label off that one
   value, so a fleet nobody had armed read as a fleet-wide alarm and the word
   an operator most needs to trust became the word they learn to ignore
   (#203).

   Paused outranks disarmed for the same reason the collector's note does:
   pausing comments the tick line out, so a paused box IS disarmed (`wire:
   paused implies disarmed`, test/floor/units.sh) — and "the operator did this, the
   console undoes it" is the more useful sentence than "nothing is armed".

   "" for a genuinely silent box, and for every DEMO unit: reserving the alarm
   is the whole point, and the art-preview toggles set a state with no unit
   behind it. */
function stoppedWord(d){
  if(!LIVE||!d)return "";
  return d.paused?"PAUSED":d.disarmed?"DISARMED":"";
}
/* fleetState UNIT — the HUD vocabulary for one roster member. The collector's
   state deliberately keeps every non-ticking box under `offline`; this is the
   one client-side split both the counter tiles and their filter chips consume.
   Keeping dataOf() here also keeps paused/disarmed out of the live ROSTER
   projection, where those fields do not exist. */
function fleetStateData(u,d){
  /* THE STATE WORD DECIDES FIRST, and nothing below it may outrank the
     `offline` split (#611 round 5). `lock.stuck` and `authfail` are published
     unconditionally by the collector — `stuck_verdict` runs for every unit and
     `authfail` is filled straight off probe meta — while the collector's own
     ladder ranks paused/disarmed/SILENT ABOVE both. So an `offline` box
     carrying either fact is not a corner, it is what the elif-chain produces,
     and a guard that answered before this dispatch counted a wedged SILENT box
     as `working` and an authfail SILENT box as `idle`. That is #203 from the
     other side: the tile that exists to notice something stopped went quiet
     about the box that stopped. Under-spending the alarm costs what
     over-spending it cost — the word an operator learns not to trust. */
  if(u.state==="working")return "working";
  if(u.state==="suppressed")return "suppressed";
  if(u.state==="offline")return stoppedWord(d)?"disarmed":"silent";
  /* Past the dispatch, this is the `idle` cell `applyFleet` normalised a
     working unit with no current-session object into — the only path either
     fact was ever meant to speak on. A stuck lock is the deliberate
     exception the collector and the alert ladder both call working/STUCK. */
  if(LIVE&&d&&d.lock&&d.lock.stuck)return "working";
  /* One sentence for LIMITED, and `populateDash` reads the same one for the
     console: an AUTH-blocked box is badged AUTH by the alert ladder, so the
     tile and the chip must not be the last readers still calling it limited. */
  return LIVE&&d&&d.limited&&!(d.authfail&&d.authfail.length)?"limited":"idle";
}
function fleetState(u){
  return fleetStateData(u,dataOf(UNITID(u),u.room));
}
function matchesFloorFilter(u){
  return (floorFilter.state==="all"||fleetState(u)===floorFilter.state)
    &&(floorFilter.role==="all"||u.room===floorFilter.role);
}
function matchedFloorUnits(){return ROSTER.filter(matchesFloorFilter);}
/* fleetCounts() — the roster split four ways instead of three. The fourth
   bucket is exactly stoppedWord above, so the page never invents a category
   /api/fleet does not already carry, and `silent` counts only what the alarm
   is for. Shared by the header's stage counts and the HUD tiles: two counters
   that disagreed about what SILENT means would be worse than one that was
   wrong. */
function fleetCounts(){
  var c={working:0,idle:0,suppressed:0,limited:0,disarmed:0,silent:0};
  ROSTER.forEach(function(u){c[fleetState(u)]++;});
  return c;
}
/* Keep the floor's stage summary as shared data for the DOM tiles and FLOORDEV.
   The fixed DOM fleetbar superseded the old canvas counter run; painting both
   in the same 70px band makes neither readable. */
function stageCounts(){
  var c=fleetCounts();
  var stat=[[c.silent+" SILENT","#ff5147"],[c.idle+" IDLE","#5fce9b"],[c.working+" WORKING","#f7bd4e"]];
  if(c.suppressed)stat.splice(1,0,[c.suppressed+" SUPPRESSED","#f28b54"]);
  if(c.limited)stat.splice(1,0,[c.limited+" LIMITED","#ff5147"]);
  /* Only when non-zero, on the ALERT counter's rule below: a permanent
     "0 DISARMED" is furniture. SILENT stays unconditional either way — an
     operator reading a calm fleet is entitled to see the alarm counter sitting
     at zero, not to infer it from an absence. */
  if(c.disarmed)stat.splice(1,0,[c.disarmed+" DISARMED","#8aa0b8"]);
  /* Prepended so it reads outermost in the DOM tile run, and only when
     non-zero: a permanent "0 ALERT" is furniture. These units are ALSO
     counted as working or idle above — that is correct, they are, and the
     point of this counter is that the state they are in is not the whole
     story. */
  var alerts=LIVE?ROSTER.filter(function(u){return alertOf(u)!=="";}).length:0;
  if(alerts)stat.unshift([alerts+" ALERT","#ff5147"]);
  return stat;
}
/* The canvas byline, exactly as drawn. The DOM fleetbar owns the brand, repo,
   counters and unit count; repeating them here visibly double-paints its fixed
   70px band. Kept as data so the browser walk can observe the live paint path
   without maintaining a test-only copy. */
function floorHeaderLabels(){
  var version=(LIVEMETA&&LIVEMETA.version)||"version unavailable";
  var y=floorHeaderY();
  var labels=[
    {text:version,x:26,y:y,font:"10px ui-monospace,monospace",color:"#7f93aa",align:"left"},
    {text:"scroll · click a unit to zoom in",after:version,x:26,y:y,font:"10px ui-monospace,monospace",color:"#46566a",align:"left"}
  ];
  labels.forEach(function(h){
    X.font=h.font;
    if(h.after)h.x+=X.measureText(h.after).width+18;
    h.width=X.measureText(h.text).width;
  });
  return labels;
}
/* Reserve a canvas lane below every visible child of the responsive DOM bar.
   Vertical separation makes the result independent of the install-root length
   embedded in `crew --version`; a longer byline can never run back through the
   badge or counter row. */
function floorHeaderY(){
  var bar=document.querySelector(".fleetbar"),bottom=70;
  if(bar){[].forEach.call(bar.querySelectorAll("*"),function(el){
    var r=el.getBoundingClientRect(),s=getComputedStyle(el);
    if(r.width>0&&r.height>0&&s.display!=="none"&&s.visibility!=="hidden")bottom=Math.max(bottom,r.bottom);
  });}
  return Math.ceil(bottom)+18;
}
function drawAlertBadge(cx,cy,u,cw){
  var a=alertOf(u);if(!a)return;
  X.save();
  X.font="700 9px ui-monospace,monospace";
  /* Top-centre: the tile's own corners carry telemetry now, and an alert is
     the one mark allowed to shove everything else aside. */
  var w=X.measureText(a).width+12,h=15,bx=cx+(cw-w)/2,by=cy+9;
  X.fillStyle="rgba(255,81,71,0.92)";rr(X,bx,by,w,h,4);X.fill();
  /* Pulse, because these two states are otherwise indistinguishable from a
     calm cell at a glance across a wide grid. */
  X.globalAlpha=0.35+0.35*Math.sin(t2()/260);
  X.strokeStyle="#ff5147";X.lineWidth=2;rr(X,bx-2,by-2,w+4,h+4,6);X.stroke();
  X.globalAlpha=1;
  X.fillStyle="#0b0f16";X.textAlign="center";X.textBaseline="middle";
  X.fillText(a,bx+w/2,by+h/2+0.5);
  X.restore();X.textAlign="left";X.textBaseline="alphabetic";
}
function t2(){return Date.now();}
function drawFloorHeader(t){
  X.textBaseline="alphabetic";
  floorHeaderLabels().forEach(function(h){
    X.textAlign=h.align;X.font=h.font;X.fillStyle=h.color;
    X.fillText(h.text,h.x,h.y);
  });
  X.textAlign="left";
}
function syncToggles(){
  var un=document.getElementById("un");if(!un)return;
  [].forEach.call(un.querySelectorAll("button"),function(b){b.classList.toggle("on",b.dataset.a===AGENT);});
  [].forEach.call(document.getElementById("rm").querySelectorAll("button"),function(b){b.classList.toggle("on",b.dataset.r===ROOM);});
  [].forEach.call(document.getElementById("stg").querySelectorAll("button"),function(b){b.className=(b.dataset.s===STATE?"on "+(STATE==="working"?"w":STATE==="offline"?"o":""):"");});
}
function focusUnit(i){var u=ROSTER[i];AGENT=u.agent;ROOM=u.room;STATE=u.state;BOX=UNITID(u);VIEW="room";syncToggles();refreshChrome();document.body.className="room";populateDash();}
function toFloor(){VIEW="floor";document.body.className="floor";buildOps();syncEmptyFloor();}

/* ---- fleet data + command-center HUD ---- */
var VCOL={claude:"#ff9a3c",codex:"#37d4a6",grok:"#b07cff",kimi:"#ff72b6"};
var REPONAMES=["ceremony","cast","box","rig","incubator","crew"];
var REPOC={ceremony:"#e0913d",cast:"#3fb0e6",box:"#7bc86a",rig:"#e0664a",incubator:"#a884ff",crew:"#e6c34a"};
var dataCache={}, floorFilter={state:"all",role:"all"};
function VENDORCOL(a){return VCOL[a]||"#8aa0b8";}
function hexA(h,a){h=h.replace("#","");return "rgba("+parseInt(h.substr(0,2),16)+","+parseInt(h.substr(2,2),16)+","+parseInt(h.substr(4,2),16)+","+a+")";}
function pad2(n){return (n<10?"0":"")+n;}
/* #758 — the wall-clock HH:MM of the store's last ok pull, in the viewer's
   zone; "—" when the stamp is missing or unreadable. */
function storedClock(iso){var t=iso?new Date(iso):null;if(!t||isNaN(t.getTime()))return "—";return pad2(t.getHours())+":"+pad2(t.getMinutes());}
function ri2(a,b){return a+Math.floor(Math.random()*(b-a+1));}
function kindOf(room){return room==="builder"?"build":room==="reviewer"?"review":"triage";}
function outcomeFor(k){return k==="build"?["opened PR","pushed fixups","needs-human","resumed"][ri2(0,3)]:k==="review"?["approved","changes-requested","commented"][ri2(0,2)]:["labeled ready","routed to builder","marked blocked","ruling posted"][ri2(0,3)];}
function queueRepo(q,fallback){
  var item=(q||[]).find(function(x){return x&&x.repo;});
  return item?item.repo:fallback;
}
function queueChip(q){
  var repo=q.repo;
  return '<span class="qc" style="border-color:'+(REPOC[repo]||"#3a4a60")+'">'+(repo?esc(repo)+' ':"")+(/^\d+$/.test(q.key)?"#":"")+esc(q.key)+'</span>';
}
function fmtDur(s){if(s===null||s===undefined)return "—";s=Math.max(0,Math.floor(s));var h=Math.floor(s/3600),m=Math.floor((s%3600)/60),ss=s%60;return h?(h+"h "+pad2(m)+"m"):(m?(m+"m "+pad2(ss)+"s"):(ss+"s"));}
function sessionRc(s){return s.rc===null||s.rc===undefined?"-":s.rc;}
function sessionClass(s){return s.out==="TERMINAL"?"terminal":s.rc===null||s.rc===undefined||s.rc?"cr":s.acted==="no"?"noop":"ok";}
/* peak_rss= arrives in KiB and is absent whenever the engine did not measure
   the session (#473). Absent is not zero: `!k` renders the same em dash the
   other unmeasured rows use, so a box whose kernel reports no VmHWM reads as
   "no figure" and never as a session that used no memory. */
function fmtKiB(k){if(!k)return "—";return k>=1048576?(k/1048576).toFixed(1)+"G":k>=1024?Math.round(k/1024)+"M":k+"K";}
/* #483 D1 — the box vitals record as (label, text) rows.

   THIS FUNCTION IS HALF OF A CONTRACT WITH cli/crew. The acceptance criterion
   is that this page and `crew status` render the same record and CANNOT
   disagree, and the only way two readers in two languages hold that is if the
   strings themselves are pinned rather than each side owning a phrase-book.
   So the labels and the text are byte-for-byte what cli/crew's
   `vitals_rows()` emits, and fleet-floor/test/cli.sh drives ONE captured
   record through both and asserts the outputs are identical. Change a word
   here and that test reds until the other reader says the same word.

   Figures stay in the MiB the probe measured. A prettier `5.8 GiB` here
   against `5948 MiB` there would be exactly the disagreement the criterion
   forbids, dressed as a courtesy.

   A row is emitted only when every field it needs is on the record. D6 is
   per-field degradation, so a box that could not read `free` is missing the
   memory row entirely rather than carrying a row of dashes — which reads as a
   measurement of nothing rather than as an absence. */
function boxVitalsRows(v){
  if(!v)return [];
  var f=v.fields||{},s=v.series||[],rows=[];
  function has(){for(var i=0;i<arguments.length;i++)if(f[arguments[i]]===undefined)return false;return true;}
  if(has("cores"))rows.push(["Cores",f.cores+(has("load1")?" · load1 "+f.load1:"")]);
  if(has("mem_total_mb","mem_avail_mb"))
    rows.push(["Memory",f.mem_avail_mb+" of "+f.mem_total_mb+" MiB available"
      +(has("mem_shared_mb")?" · "+f.mem_shared_mb+" MiB shared":"")]);
  if(has("disk_total_mb","disk_used_mb","disk_pct"))
    rows.push(["Disk",f.disk_used_mb+" of "+f.disk_total_mb+" MiB used · "+f.disk_pct+"%"]);
  /* Always both numbers, never a derived "swap is fine". The pair IS the
     finding: 0 active beside 12288 configured is a swapfile holding a quarter
     of the disk and doing nothing, and either number alone looks explicable. */
  if(has("swap_active_mb","swap_configured_mb"))
    rows.push(["Swap",f.swap_active_mb+" MiB active of "+f.swap_configured_mb+" MiB configured"]);
  /* D5 — the backfilled series, so the disk history starts where the box did.
     Purely historical: the live reading is the Disk row directly above, and
     splicing the two into one arrow would put a figure measured this second
     at the end of a series read out of a log. */
  if(s.length)rows.push(["Disk since",s[0].ts+" · "
    +(s.length>1?s[0].pct+"% → "+s[s.length-1].pct+"%":s[0].pct+"%")
    +" over "+s.length+" boot reading"+(s.length===1?"":"s")]);
  if(has("platform"))rows.push(["Platform",f.platform+(has("os")?" · "+f.os:"")]);
  /* One row each, and the text is the record's own — see units.py's
     _vitals_finding. A finding this page reworded would be a finding an
     operator could not grep the log for. */
  (v.findings||[]).forEach(function(x){rows.push(["Finding",x]);});
  return rows;
}
function tickHealthWindow(s){return s%86400===0?(s/86400)+"d":s%3600===0?(s/3600)+"h":s+"s";}
function tickHealthDuration(s){return s>=86400?Math.floor(s/86400)+"d "+Math.floor((s%86400)/3600)+"h":s>=3600?Math.floor(s/3600)+"h "+Math.floor((s%3600)/60)+"m":s>=60?Math.floor(s/60)+"m":s+"s";}
function tickHealthRows(h){
  if(!h)return [];
  var w=tickHealthWindow(h.window),rows=[];
  rows.push(["Last tick ("+w+" window)",h.last_tick_age===null?"unknown":tickHealthDuration(h.last_tick_age)+" ago"]);
  rows.push(["Busy ticks ("+w+" window)",h.ticks?String(h.busy)+"/"+h.ticks+" ("+(100*h.busy/h.ticks).toFixed(1)+"%)":"unknown"]);
  (h.kinds||[]).forEach(function(k){
    var holds=Object.keys(k.holds||{}).map(function(reason){return reason+":"+k.holds[reason];}).join(", ")||"none";
    rows.push([k.kind+" skips/holds ("+w+" window)",k.skips+" skips · "+holds]);
    rows.push([k.kind+" outcome streak ("+w+" window)",k.outcome?k.outcome+" ×"+k.streak:"unknown"]);
  });
  return rows;
}
function genData(room){var kind=kindOf(room),qn=ri2(2,6),q=[];for(var k=0;k<qn;k++)q.push({repo:REPONAMES[ri2(0,5)],key:ri2(11,148)});
  var sess=[],ago=ri2(1,5),cap=kind==="triage"?2400:7200;for(var s=0;s<11;s++){var rc=Math.random()<0.12?1:0;sess.push({ago:ago,kind:kind,rc:rc,dur:ri2(45,cap),out:rc?"aborted (budget)":outcomeFor(kind),peak:ri2(180000,2600000)});ago+=ri2(4,11);}
  var durs=sess.map(function(x){return x.dur;}),ok=sess.filter(function(x){return !x.rc;}).length;
  var spark=[];for(var sp=0;sp<22;sp++)spark.push(0.14+Math.random()*0.86);
  var nowS=Math.floor(Date.now()/1000),cur={key:(kind==="triage"?"board":REPONAMES[ri2(0,5)]+"#"+ri2(11,148)),start:nowS-ri2(20,Math.min(cap,5200))};
  return {kind:kind,queue:q,sessions:sess,up:{h:ri2(1,71),m:ri2(0,59)},repo:queueRepo(q,"crew"),spark:spark,
    longest:Math.max.apply(null,durs),avg:Math.round(durs.reduce(function(a,b){return a+b;},0)/durs.length),success:Math.round(100*ok/sess.length),today:ri2(8,46),cur:cur};}
function fleetMetric(){var lb=0,lr=0,lt=0,all=[];ROSTER.forEach(function(u){var d=dataOf(UNITID(u),u.room);all=all.concat(d.sessions.map(function(s){return s.dur;}));if(u.room==="builder")lb=Math.max(lb,d.longest);else if(u.room==="reviewer")lr=Math.max(lr,d.longest);else lt=Math.max(lt,d.longest);});return {build:lb,review:lr,triage:lt,avg:all.length?Math.round(all.reduce(function(a,b){return a+b;},0)/all.length):0};}
function dataOf(box,room){if(!dataCache[box])dataCache[box]=LIVE?emptyData(room||ROOM):genData(room||ROOM);return dataCache[box];}
function emptyData(room){return {kind:kindOf(room),queue:[],sessions:[],up:{h:0,m:0},repo:"",spark:[],longest:0,avg:0,success:0,today:0,cur:null,live:true,gh:"unknown",vendor:"unknown",engine:"",integrity:"",cron:{ok:false,last:null,age:null},note:"",paused:false,disarmed:false,box:"",logs:[],ping:null,lock:{held:null,stuck:false,ceiling:null,bound:null},authfail:[],limited:null,floorEvents:[],limitDropped:null,vitals:null,tickHealth:null};}

/* ===================== LIVE MODE (collector at /api, see server/floor.py) =====================
   The collector polls every box from the operator host over `box exec` and
   serves the result here; operator actions POST back and are applied the same
   way. The boxes still initiate nothing and run nothing extra — the host's
   existing control channel does both halves. */
var LIVEMETA=null, POLL_MS=15000, seenSess={};
/* When the snapshot on screen was received. The stuck timer counts from the
   lock age the box reported PLUS the time since we heard it, so the readout
   keeps advancing between polls instead of freezing at a stale number and
   then jumping a minute. */
var LASTPOLL=Date.now();
/* Absolute, credential-free. An operator who bookmarks the page as
   http://user:pass@host:port/ leaves credentials in the document URL, and a
   relative fetch inherits them — which the browser then refuses to construct a
   Request from, silently stranding the page in DEMO. location.origin drops
   them. */
/* Live repo strings are FULL owner/repo names — repos.txt holds
   "heavy-duty/ceremony", and the duty log's `attention: $repo#$num` carries the
   owner too. Prefixing the org unconditionally produced
   github.com/heavy-duty/heavy-duty%2Fcrew on every live unit. Encode per path
   segment so a slash stays a slash. */
function repoURL(repo){
  var parts=String(repo).split("/").filter(Boolean).map(encodeURIComponent);
  if(parts.length<2)parts=["heavy-duty"].concat(parts);
  return "https://github.com/"+parts.join("/");
}
function apiURL(path){return (location.origin&&location.origin!=="null"?location.origin:"")+path;}
function api(path,opts){return fetch(apiURL(path),opts||{}).then(function(r){
  if(r.status===401){throw new Error("unauthorized");}
  /* A partly-failed fleet action answers 500 with the per-box detail in the
     body. Throwing on !ok would discard exactly the part worth showing and
     leave the operator with a bare status code. */
  return r.json().then(function(j){
    /* `j.refused` rides beside `j.results` for the same reason: a refused
       restart (409, #486) carries the operator's next step in its body, and
       throwing would replace that sentence with a status code. */
    if(!r.ok&&!(j&&(j.results||j.refused)))throw new Error((j&&j.error)||("HTTP "+r.status));
    return j;
  },function(){throw new Error("HTTP "+r.status);});});}
/* Server unit -> the record every panel already reads, so nothing downstream
   has to know which mode it is in. */
function liveData(u){
  var d=emptyData(u.room);
  d.box=u.box;d.queue=u.queue||[];d.sessions=u.sessions||[];d.up=u.up||{h:0,m:0};
  d.repo=queueRepo(d.queue,u.repo||"");d.spark=(u.spark&&u.spark.length?u.spark:[]);d.longest=u.longest||0;
  d.avg=u.avg||0;d.success=u.success||0;d.today=u.today||0;d.cur=u.cur||null;
  d.gh=u.gh;d.vendor=u.vendor;d.engine=u.engine||"";d.cron=u.cron||d.cron;
  /* #159's verdict about that stamp. Defaulted to "" like the fields below,
     and for the same reason: a collector older than this field reports none,
     and "not known" must render as no mark at all — never as `current`, which
     would be the one wrong answer, and never as a crash mid-draw. */
  d.integrity=u.integrity||"";
  /* The ping tier and the flow-reported credential state. Defaulted rather
     than assigned straight through: a collector older than these fields, or a
     unit built from the error path, must render as "not known" and never as a
     missing-property crash mid-draw. */
  d.ping=u.ping||null;d.lock=u.lock||{held:null,stuck:false,ceiling:null,bound:null};
  /* #483 — the box vitals record, parsed by the collector off the same
     duty.log line `crew status` reads. `null` on a collector older than the
     field AND on a box whose engine is older than the probe, which is the
     same rendering either way: the section is omitted rather than drawn with
     dashes in it, because a row of em-dashes reads as a box that answered and
     had nothing to say. */
  d.vitals=u.vitals||null;
  d.tickHealth=u.tick_health||null;
  d.suppression=u.suppression||{active:false,age:null,kind:"",key:""};
  d.authfail=u.authfail||[];
  d.limited=u.limited||null;d.floorEvents=u.floor_events||[];
  d.limitDropped=u.limit_dropped===undefined?null:u.limit_dropped;
  d.note=u.note||"";d.paused=!!u.paused;d.logs=u.logs||[];d.repos=u.repos||[];
  /* #758 — WHERE the record came from. "stored" is a box that did not answer,
     served from the host's store with the time of its last ok pull; the panel
     marks it so an old reading is never taken for a fresh one. A collector
     older than the field sends none, which renders as no mark. */
  d.source=u.source||"";d.storedAt=u.stored_at||null;
  /* #189 gave the collector this flag and nothing here read it, so every
     deliberately-stopped box came through as a bare state:"offline" and got
     shouted at as SILENT (#203). Defaulted like the fields above: a collector
     older than #189 reports no `disarmed` at all, and "not known" must render
     as "not disarmed", never as a crash mid-draw. */
  d.disarmed=!!u.disarmed;
  if(d.cur&&d.cur.kind)d.kind=d.cur.kind;
  return d;
}
/* DECLARED — how many boxes the fleet roster names, which is exactly
   /api/fleet's length. ROSTER.length is how many get a console, and since #204
   those are two different numbers: the grid draws what is DEPLOYED, the count
   keeps saying what is DECLARED, and neither reader has to guess the other. */
var DECLARED=0;
/* deployed UNIT — does this roster member get a console?
   Reads the collector's `hired` verdict and nothing else. The engine string is
   deliberately NOT consulted here: it is empty for a never-created box, a
   stopped box, an unreachable box and an unhired one, and only two of those
   four are hidden. That inference is the defect #308 fixes in `crew status`,
   and the whole point of the collector publishing a verdict is that this page
   never has to repeat it (#204).

   Hidden: `no` — the box does not exist, or it answered and reported no
   engine. Kept: `yes`, and `unknown` — stopped and unreachable boxes, whose
   hired state cannot be measured while they are in that state. Hiding the
   unreachable one would drop the hired-and-gone-dark box, which is the single
   thing this page most exists to show, so "cannot tell" keeps the console.

   A collector older than #204 sends no `hired` at all. That is `undefined`,
   not `"no"`, so it is kept — the same fail-safe direction as `disarmed`
   above: an unknown field renders as "nothing to hide", never as a fleet that
   silently empties itself against a stale server. */
function deployed(u){return !u||u.hired!=="no";}
function applyFleet(snap){
  if(!snap||!snap.units)return;
  if(!snap.units.length){
    /* A well-formed answer with no boxes is a FACT, not a failed poll. Falling
       back to DEMO here would show an operator a floor full of plausible
       placeholder boxes while a real collector sat behind it reporting an
       empty roster. Once live, though, an empty poll keeps the last snapshot
       rather than blanking a fleet that was there a second ago. */
    if(!LIVE){LIVE=true;LIVEMETA=snap;ROSTER=[];dataCache={};DECLARED=0;goLive();
      buildTiles();buildOps();syncEmptyFloor();
      setStatus("collector reports an empty fleet — check the resolved fleet roster",true);}
    return;
  }
  LIVEMETA=snap;
  var first=!LIVE;LIVE=true;LASTPOLL=Date.now();
  var roster=[],cache={};
  DECLARED=snap.units.length;
  snap.units.forEach(function(u){
    /* working means "a session is open"; without one the cell has nothing to
       count up from, so it is standby however the probe was labelled. */
    var st=(u.state==="working"&&!u.cur)?"idle":u.state;
    /* Cached for EVERY roster member, hidden or not: the cache is keyed by box
       and read by the counts below, and a hidden box still contributes its
       facts to them. Only the grid is filtered. */
    cache[u.box]=liveData(u);
    if(deployed(u))roster.push({agent:u.agent,room:u.room,state:st,box:u.box,note:u.note||""});
  });
  ROSTER=roster;dataCache=cache;
  if(first)goLive();
  /* Keep the operator's current focus pinned across polls rather than snapping
     the view back to the floor every 15 seconds. */
  var me=ROSTER.filter(function(u){return UNITID(u)===BOX;})[0];
  if(me){STATE=me.state;AGENT=me.agent;ROOM=me.room;}
  else if(VIEW==="room"){
    /* The roster is re-read every poll, so the box an operator is standing in
       can be removed, renamed, or `crew new`-ed away underneath them. Pinning
       the focus across polls is deliberate, but pinning it to something that
       no longer exists renders a plausible, quiet, entirely fictional console
       — the phantom-box twin of a frozen fleet that looks calm. Say so and go
       back to the floor, which is the only view that is still true. */
    var gone=BOX;
    /* Two ways to lose the box you are standing in, and they want different
       sentences. Removed from the roster is the phantom-box case above. Still
       declared but no longer deployed is the #204 filter closing a console the
       operator has open — the box torn down and re-created empty, or an engine
       removed by hand — and telling them it left the fleet would be false. */
    var still=snap.units.filter(function(u){return u.box===gone;})[0];
    toFloor();
    setStatus(still
      ? gone+" is not hired — returned to the floor"
      : gone+" is no longer in the fleet — returned to the floor",true);
    buildTiles();buildOps();syncEmptyFloor();
    return;
  }
  buildTiles();buildOps();syncToggles();refreshChrome();syncEmptyFloor();
  if(VIEW==="room")populateDash();
  liveTicker(snap);
}

/* Real duty.log events only: each poll emits the SESSION lines that are new
   since the last one, so the ticker is evidence rather than atmosphere. */
function liveTicker(snap){
  var s=document.getElementById("stream");if(!s)return;
  var fresh=[],next={},primed=seenSess.__primed;
  snap.units.forEach(function(u){
    (u.sessions||[]).slice(0,6).forEach(function(x){
      var id=u.box+"|"+x.kind+"|"+x.key+"|"+x.dur+"|"+x.out+"|"+x.acted;
      next[id]=1;
      if(seenSess[id]||!primed)return;
      var state=x.acted==="no"?" no-op":"";
      var tail=x.reply?" — "+x.reply:"";
      fresh.push({u:u,msg:"SESSION END kind="+x.kind+" key="+x.key+" rc="+sessionRc(x)+" outcome="+x.out+" acted="+x.acted+state+tail,rc:x.rc,unknown:x.rc===null||x.rc===undefined,noop:x.acted==="no",ago:x.ago});
    });
    if(u.cur){
      var cid=u.box+"|open|"+u.cur.kind+"|"+u.cur.key+"|"+u.cur.start;
      next[cid]=1;
      if(!seenSess[cid]&&primed)fresh.push({u:u,msg:"SESSION START kind="+u.cur.kind+" key="+u.cur.key,rc:0});
    }
  });
  /* Carry only the ids still in this snapshot. duty.log is append-only, so an
     id that has aged out of the window cannot come back and be re-emitted —
     which keeps the dedup set bounded on a page left open for days. */
  next.__primed=1;seenSess=next;
  fresh.sort(function(a,b){return (b.ago||0)-(a.ago||0);});
  fresh.forEach(function(f){
    var el=document.createElement("div");el.className="l";
    var m=esc(f.msg);
    m=f.rc||f.unknown?m.replace(/rc=(?:\d+|-)/,'<span class="cr">rc='+(f.unknown?'-':f.rc)+'</span>'):(f.noop?m.replace(/(acted=no no-op)/,'<span class="noop">$1</span>'):m.replace(/(outcome=.*)$/,'<span class="ok">$1</span>'));
    el.innerHTML='<span class="tt">'+clockStr()+'</span><span class="u" style="color:'+VENDORCOL(f.u.agent)+'">'+esc(f.u.box)+'</span><span class="m">'+m+'</span>';
    s.appendChild(el);
  });
  while(s.childNodes.length>30)s.removeChild(s.firstChild);
  if(fresh.length)s.scrollTop=s.scrollHeight;
}
/* A live page whose collector has died keeps rendering the last snapshot, and
   a frozen fleet looks exactly like a calm one — the same trap the engine's
   own "silence = dead" rule exists to close, one level up. After two missed
   polls the page says so instead of quietly showing yesterday's news. */
var pollFails=0, STALE_AFTER=2;
function pollFleet(){
  /* Opened from disk there is nothing to poll, and asking anyway just prints a
     CORS failure in the console of a page that is working exactly as intended. */
  if(location.protocol==="file:")return;
  api("/api/fleet").then(function(snap){
    pollFails=0;setStale(false);applyFleet(snap);
  }).catch(function(e){
    if(String(e.message)==="unauthorized")return setStatus("unauthorized — reload and sign in",true);
    /* Never went live at all: no collector, so DEMO is the honest state and
       there is nothing stale about it. */
    if(!LIVE)return;
    if(++pollFails>=STALE_AFTER)setStale(true,e.message);
  });
}
function setStale(on,why){
  var badges=document.querySelectorAll(".demo-badge");
  [].forEach.call(badges,function(b){
    b.classList.toggle("stale",!!on);
    if(on){b.textContent="◈ STALE";b.title="The collector stopped answering — this is the last snapshot, not the current fleet.";}
    else if(LIVE){b.textContent="◈ LIVE";b.title="Live telemetry — every box polled from the operator host over 'box exec'.";}
  });
  if(on)setStatus("collector unreachable — frozen at "+((LIVEMETA&&LIVEMETA.generated)||"?")+(why?" ("+why+")":""),true);
}
function setStatus(msg,bad){
  var el=document.getElementById("livestat");if(!el)return;
  el.textContent=msg;el.style.color=bad?"#ff5147":"#5fce9b";
}
/* One-time flip of everything the DEMO build deliberately nailed shut. */
function goLive(){
  [].forEach.call(document.querySelectorAll(".demo-badge"),function(b){
    b.textContent="◈ LIVE";b.classList.add("live");
    b.title="Live telemetry — every box polled from the operator host over 'box exec'.";
  });
  ["g-start","g-stop","g-wake","g-reg","g-roster","a-pause","a-restart","c-send"].forEach(function(id){
    var e=document.getElementById(id);if(e){e.classList.remove("woff");e.title="";}
  });
  var cin=document.getElementById("c-in");
  if(cin){cin.disabled=false;cin.classList.remove("woff");cin.placeholder="Send a prompt to the agent…";}
  var s=document.getElementById("stream");if(s)s.innerHTML="";
}
/* Operator actions (#39). Every one is applied by the host with `box exec`,
   `box down`, `box start` or — for a guest that can no longer schedule its own
   shutdown — `box incus <box> -- stop --force` (#486); the reply carries
   per-box rc so a refused or failed action is reported instead of being
   animated as success, and a `step` naming which of those paths it took. */
/* cmdSay ACTION RESULTS — the status line for an action that SUCCEEDED.
   An action that escalated says so after the fact, not only in the confirm
   before it: `restart ok` alone hides that this guest was killed where it
   stood rather than asked to stop, and this line is the one place an operator
   looks afterwards (#486). Read off the reply's own `step` — the collector's
   record of the path it took — never re-derived from the fleet's state here,
   which is the mistake this round fixed one function over. Silent for
   `force-stop` itself, where the verb the operator fired is the disclosure. */
function forcedBoxes(action,results){
  /* `&& x.ok`: a force stop that itself FAILED did not kill anything, and the
     failed row is already named in the error text. Inert on the success path,
     where every row is ok by construction. */
  return action==="force-stop"?[]:(results||[]).filter(function(x){return x.step==="force-stop"&&x.ok;}).map(function(x){return x.box;});
}
function cmdSay(action,results){
  var forced=forcedBoxes(action,results);
  return action+" ok"+(forced.length?" — force-stopped "+forced.join(", "):"");
}
/* ...and the same disclosure when the action FAILED. A restart that force-
   stopped and then could not start the box rendered `restart FAILED — box:
   …` with no word that the guest had already been killed: mute in exactly the
   case the disclosure exists for, and the case where an operator most needs
   to know the session is gone rather than merely interrupted. */
function cmdSayFail(action,results,why){
  var forced=forcedBoxes(action,results);
  return action+" FAILED — "+(forced.length?"force-stopped "+forced.join(", ")+", then ":"")+why;
}
function cmd(action,extra){
  var body=Object.assign({action:action},extra||{});
  setStatus(action+"…",false);
  return api("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})
    .then(function(r){
      /* Strict false, not falsy: a not-created roster box reports ok:null
         (inventory drift, not a refusal, #77) and must not read as a box that
         needs a look. Only ok===false is a box that was there and refused. */
      var bad=(r.results||[]).filter(function(x){return x.ok===false;});
      /* Name the box that refused. On a fleet-wide action "start-all FAILED"
         alone tells the operator nothing about which box needs a look. */
      var why=bad.length?(bad[0].box+": "+bad[0].out+(bad.length>1?" (+"+(bad.length-1)+" more)":"")):(r.error||"?");
      /* REFUSED is not FAILED. The collector answers 409 when what the operator
         confirmed and what the box is now have come apart (#486): nothing ran,
         so saying the action failed would describe a host that was never
         touched. The sentence the collector wrote is the whole message — it
         names which way the box moved and that nothing was done — and the
         pollFleet() below reloads the verdict, so the next click confirms the
         path that is true now. */
      setStatus(r.refused?(action+" refused — "+(r.error||"?")):(r.ok?cmdSay(action,r.results):cmdSayFail(action,r.results,why)),!r.ok);
      pollFleet();
      return r;
    })
    .catch(function(e){setStatus(action+" failed: "+e.message,true);});
}
function esc(s){return String(s).replace(/[&<>]/g,function(c){return c==="&"?"&amp;":c==="<"?"&lt;":"&gt;";});}
function stampVersion(s){var m=String(s||"").match(/^crew@([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?)(?:\s|$)/);return m?m[1]:"unknown";}
function clockStr(){var d=new Date();return pad2(d.getUTCHours())+":"+pad2(d.getUTCMinutes())+":"+pad2(d.getUTCSeconds());}
/* The floor with nothing on it. #204 made an empty grid a state an operator
   reaches on purpose — a roster written before the first `crew hire` draws no
   console at all — and a blank stage with no words on it is the "fresh
   operator sees a blank page and no next step" the issue names as a
   requirement on the fix, not a side effect of it.

   DOM, not canvas: the grid is painted every frame and this is not, so it
   belongs with the rest of the chrome the fleetbar owns — and a rendered-page
   assertion can read it, which is the regression shape #203 recorded, where
   every collector assertion stayed green while the page said the wrong thing.

   It says the two things the count alone cannot: how many boxes are declared,
   and the command that turns one of them into a console. */
function syncEmptyFloor(){
  var el=document.getElementById("emptyfloor");if(!el)return;
  var show=LIVE&&VIEW==="floor"&&!ROSTER.length;
  el.classList.toggle("on",show);
  if(!show){el.innerHTML="";return;}
  el.innerHTML=DECLARED
    ? '<div class="eh">NO BOX IS HIRED YET</div>'
      +'<div class="eb">The fleet roster declares <b>'+DECLARED+'</b> box'
      +(DECLARED===1?'':'es')+', and none of them is running an engine. '
      +'A console appears here as its box is hired.</div>'
      +'<div class="ec">crew hire &lt;box&gt;</div>'
    : '<div class="eh">THE FLEET ROSTER IS EMPTY</div>'
      +'<div class="eb">No box is declared, so there is nothing to hire yet. '
      +'Add boxes to the fleet roster, then create and hire them.</div>'
      +'<div class="ec">crew new &lt;box&gt;</div>';
}
function buildTiles(){var ct=fleetCounts(),q=0;ROSTER.forEach(function(u){q+=dataOf(UNITID(u),u.room).queue.length;});
  function tl(n,l,c,al,ti){return '<div class="tile'+(al?' alert':'')+'"'+(ti?' title="'+esc(ti)+'"':'')+'><span class="n" style="color:'+c+'">'+n+'</span><span class="l">'+l+'</span></div>';}
  /* `disarmed` sits between idle and silent because that is where it belongs
     on the operator's ladder: nothing is wrong, nothing is running. It is
     never given the alert class — the pulsing red border is the fleet's one
     "look at this now" mark, and a fleet the operator disarmed on purpose must
     not be able to trigger it (#189, #203). Five tiles became six rather than
     six meanings sharing five tiles. */
  /* `units` counts what the fleet DECLARES, which is what /api/fleet carries
     and what `crew status` lists — unchanged by #204's grid filter, so the two
     readers still agree about how big the fleet is. In DEMO there is no
     collector and no declared count, so the placeholder roster is its own
     answer. */
  var declared=LIVE?DECLARED:ROSTER.length;
  /* ...and `hired` says how many of them got a console, ONLY when that is a
     different number. A permanent "26 hired" beside "26 units" is furniture on
     every healthy fleet — the same rule DISARMED and ALERT already follow —
     while a fleet with boxes missing from the grid must never look like a
     fleet that is simply smaller. This tile is the "visible count rather than
     a silent omission" the issue asks for. */
  var hidden=declared-ROSTER.length;
  var hire=hidden>0?tl(ROSTER.length,"hired","#8aa0b8",false,
    hidden+(hidden===1?" declared box has":" declared boxes have")
    +" no console: not hired — crew hire <box>"):"";
  var limited=ct.limited?tl(ct.limited,"limited","#ff5147",true):"";
  var el=document.getElementById("tiles");if(el)el.innerHTML=tl(declared,"units","#c7d4e4")+hire+tl(ct.working,"working","#f7bd4e")+tl(ct.idle,"idle","#5fce9b")+tl(ct.suppressed,"suppressed","#f28b54",ct.suppressed>0)+limited+tl(ct.disarmed,"disarmed","#8aa0b8")+tl(ct.silent,"silent","#ff5147",ct.silent>0)+tl(q,"queued","#5fd6ff");}
function populateDash(){
  if(VIEW!=="room")return;
  /* The art-preview toggles can set any STATE; live data may disagree. Only
     claim a session is running when there is one to count. */
  var d=dataOf(BOX,ROOM),id=UNIT(),vc=VENDORCOL(AGENT),off=STATE==="offline",suppressed=STATE==="suppressed",limited=LIVE&&STATE==="idle"&&!(d.authfail&&d.authfail.length)&&!!d.limited,work=STATE==="working"&&!!(d.cur||!LIVE);
  /* PAUSED, DISARMED or "" — the one thing standing between this console and
     the word SILENT. Every readout below that used to key off `off` alone now
     asks this first; `off` still decides the shape of the panel, this decides
     what it is allowed to shout (#203). */
  var stw=off?stoppedWord(d):"";
  var sc=stw?"#8aa0b8":off?"#ff5147":suppressed?"#f28b54":limited?"#ff5147":work?"#f7bd4e":"#5fce9b",sl=stw||(off?"SILENT":suppressed?"SUPPRESSED":limited?"LIMITED":work?(d.kind==="build"?"BUILDING":d.kind==="review"?"REVIEWING":"DISPATCHING"):"STANDBY");
  document.getElementById("w-id").innerHTML='<div class="idc"><div class="av" style="background:'+hexA(vc,0.16)+';box-shadow:inset 0 0 0 1px '+hexA(vc,0.5)+';color:'+vc+'">'+AGENT[0].toUpperCase()+'</div><div><div class="nm">'+id+'</div><div class="rl">'+AGENT+' · '+ROOM+'</div><span class="pill" style="color:'+sc+';background:'+hexA(sc,0.14)+';box-shadow:inset 0 0 0 1px '+hexA(sc,0.4)+'">● '+sl+'</span></div></div><div class="spark" title="24h activity">'+(off?"":d.spark.map(function(v,i){return '<span style="height:'+Math.round(v*100)+'%;background:'+hexA(vc,i>=d.spark.length-4?0.95:0.42)+'"></span>';}).join(''))+'</div>';
  /* In LIVE mode every value here is what the box reported this poll; the
     DEMO strings it replaces were the placeholders #38 was filed about. */
  var vBox=off?"unreachable":"gh ✓ · box ✓", vCron=off?"SILENT":"≤2m ago", vRc=(off||!d.sessions.length)?"—":d.sessions[0].rc;
  if(LIVE){
    vBox=credGlyph("gh",d.gh)+" · "+credGlyph(AGENT,d.vendor);
    /* Was `d.paused?"PAUSED":…`, which is why paused was the one state already
       half-right here and disarmed was not started: this vital named the
       operator's pause and then fell through to SILENT for a box with no cron
       line at all. */
    vCron=stw||((d.cron.age===null||d.cron.age===undefined)?"no ticks yet":(d.cron.ok?fmtDur(d.cron.age)+" ago":"SILENT · "+fmtDur(d.cron.age)));
    if(d.note&&!d.engine)vBox=esc(d.note);
  }
  document.getElementById("w-vitals").innerHTML='<div class="wt"><span class="dot"></span>VITALS</div><div class="kv">'
    +'<span class="k">Box</span><span class="v" style="color:'+(off?"#ff5147":credColour(d))+'">'+vBox+'</span>'
    /* Directly under Box, because it answers the same question on a much
       shorter clock: Box is what the last evidence poll concluded up to a
       minute ago, Heartbeat is whether the guest answered seconds ago. */
    +'<span class="k">Heartbeat</span><span class="v" id="v-ping" style="color:'+pingColour(d)+'">'+pingText(d)+'</span>'
    +'<span class="k">Engine</span><span class="v">'+(d.engine?esc(stampVersion(d.engine))+integrityMark(d.integrity):"—")+'</span>'
    +'<span class="k">Uptime</span><span class="v">'+(off&&!LIVE?"—":(d.up.h+"h "+pad2(d.up.m)+"m"))+'</span>'
    +'<span class="k">Cron</span><span class="v" style="color:'+(stw?"#8aa0b8":off?"#ff5147":"#c7d4e4")+'">'+vCron+'</span>'
    +'<span class="k">Repo</span><span class="v">'+esc(d.repo||"—")+'</span>'
    +'<span class="k">Sessions today</span><span class="v">'+d.today+'</span>'
    +'<span class="k">Last rc</span><span class="v">'+vRc+'</span>'
    /* #483 — the box's own vitals, below the fleet-shaped rows above it.
       Omitted entirely on a box whose engine predates the probe: this widget
       has always drawn what is KNOWN, and six em-dashes claiming to be a
       hardware reading is the one thing worse than not drawing them. */
    /* #488 — what this box actually watches, and whether that is the whole
       fleet-wide list or a selection from it. Empty until /api/registries has
       answered, and in DEMO mode forever: a placeholder count here would be
       the invented telemetry #38 was filed about. */
    +boxVitalsRows(d.vitals).concat(tickHealthRows(d.tickHealth)).concat(registryRow(BOX)).map(function(r){
      return '<span class="k">'+esc(r[0])+'</span><span class="v"'
        +(r[0]==="Finding"||(r[0]==="Registry"&&/SELECTED/.test(r[1]))?' style="color:#f7bd4e"':'')+'>'+esc(r[1])+'</span>';
    }).join('')+'</div>';
  document.getElementById("w-queue").innerHTML='<div class="wt"><span class="dot"></span>WORK QUEUE · q'+d.queue.length+'</div><div class="qchips">'
    /* Live keys are whatever the duty modules logged — an issue number, but
       also "ready 2", "resume", "3 mention". Only number them when they are
       numbers. */
    +(d.queue.length?d.queue.map(queueChip).join(''):'<span style="color:#46566a;font-family:var(--mono);font-size:10px">— empty —</span>')+'</div>'
    +'<div class="wt" style="margin-top:16px"><span class="dot"></span>ACCESS</div><div class="access">'
    +ab("ac-repo","⎇ &nbsp;Open repo · "+esc(d.repo||"—"))+ab("ac-term","◱ &nbsp;Copy box shell command")
    +ab("ac-logs","▤ &nbsp;Raw session logs")+ab("ac-restart","↻ &nbsp;Restart box")
    /* #488 — the per-box override, reached from this box's own console and
       sitting with every other per-box control rather than in the fleet
       chrome. It edits a host file; nothing here reaches into the guest, so
       unlike its neighbours it stays lit on an unreachable box. */
    +ab("ac-reg","⛭ &nbsp;Watch registry")
    +'<div style="display:flex;gap:6px"><button class="lbtn pw'+(LIVE?'':' woff')+'" data-pw="off"'+(LIVE?'':' title="'+CTL_TIP+'"')+' style="flex:1;text-align:center;'+(off?'opacity:.5':'color:#ff8a7c;border-color:#3a1c1c')+'">⏻ Power off</button><button class="lbtn pw'+(LIVE?'':' woff')+'" data-pw="on"'+(LIVE?'':' title="'+CTL_TIP+'"')+' style="flex:1;text-align:center;'+(off?'color:#5fce9b;border-color:#1c3a2a':'opacity:.5')+'">⭘ Power on</button></div>'
    /* #486 D4 — a DISTINCT control that names its own violence, on its own
       line below the graceful pair rather than inside their row: an operator
       reaching for Power off must not be one mis-click from a kill. The label
       says what it DOES, not what it is called, and it is the only red-on-red
       button on the panel.

       Dimmed on a box somebody STOPPED, lit on one that stopped ANSWERING.
       The two are the same `state:"offline"` on the wire — the collector
       serves a wedged box offline on purpose — so dimming on `off` alone
       would grey out precisely the box this control exists for. The wedge
       carve-out is what makes the dim safe. */
    +'<button class="lbtn'+(LIVE?'':' woff')+'" id="ac-force"'+(LIVE?'':' title="'+CTL_TIP+'"')+' style="text-align:center;color:#ff5147;border-color:#3a1c1c'+(off&&!unreachableBox(d)?';opacity:.5':'')+'">&#10006; &nbsp;Force stop &middot; kills the guest</button></div>';
  var cs='<div class="wt"><span class="dot"></span>CURRENT SESSION</div><div class="cursess">';
  /* The note under the big card always named the real reason, so an operator
     who read the sub-text was never blind — but the word in 40px type above it
     said SILENT for all three, and that is the one the eye takes. */
  if(off)cs+='<div class="big" style="color:'+(stw?"#8aa0b8":"#ff5147")+'">— '+(stw||"SILENT")+' —</div><div class="task">'+esc(LIVE&&d.note?d.note:"no active session · cron missed")+'</div>'+(d.source==="stored"?'<div class="task" id="cur-stored" style="color:#8aa0b8">off · stored '+storedClock(d.storedAt)+'</div>':'');
  /* STUCK outranks the running-session view even though a session IS running.
     That is the whole point: cron is ticking, duty.log is fresh, the box looks
     busy — and it has been holding the same lock for longer than two tick
     boundaries. Showing the elapsed timer alone reads as healthy progress.
     No progress bar here either; there is no progress to draw. */
  else if(LIVE&&d.lock&&d.lock.stuck)cs+='<div class="big" id="cur-el" style="color:#ff5147">'+fmtDur(d.lock.held)+'</div><div class="task" id="cur-stuck" style="color:#ff8a7c">'+stuckLine(d)+'</div>';
  else if(suppressed)cs+='<div class="big" style="color:#f28b54">SUPPRESSED</div><div class="task">'+esc(d.note||"zero-action resume breaker")+'</div>';
  else if(limited)cs+='<div class="big" style="color:#ff5147">LIMITED</div><div class="task">'+esc(d.note||"operating limit")+'</div>';
  else if(work)cs+='<div class="big" id="cur-el">'+fmtDur(Math.floor(Date.now()/1000)-d.cur.start)+'</div><div class="task">'+esc(d.kind)+' · '+esc(d.cur.key)+'</div><div class="pbar"><i></i></div>';
  else cs+='<div class="big" style="color:#5fce9b">STANDBY</div><div class="task">idle · awaiting next tick</div>';
  document.getElementById("w-current").innerHTML=cs+'</div>';
  var mk=d.kind==="build"?"Build":d.kind==="review"?"Review":"Triage";
  document.getElementById("w-metrics").innerHTML='<div class="wt"><span class="dot"></span>TIME METRICS</div><div class="mgrid">'
    +'<div class="mcell"><div class="mv">'+fmtDur(d.longest)+'</div><div class="ml">Longest '+mk+'</div></div>'
    +'<div class="mcell"><div class="mv">'+fmtDur(d.avg)+'</div><div class="ml">Avg session</div></div>'
    +'<div class="mcell"><div class="mv">'+d.today+'</div><div class="ml">Runs today</div></div>'
    +'<div class="mcell"><div class="mv" style="color:'+(d.success>85?"#5fce9b":"#f7bd4e")+'">'+d.success+'%</div><div class="ml">Success rc0</div></div></div>';
  var sh='<div class="wt"><span class="dot"></span>SESSION HISTORY</div><div class="feed" id="dfeed">';
  d.sessions.forEach(function(s,i){var label=(s.acted==="no"?"no-op":s.out)+(s.reply?" — "+s.reply:"");var cls=sessionClass(s),why=s.log_unavailable==="start-aged-out"?"start aged out":s.log_unavailable==="log-reaped"?"log reaped":"log unavailable";sh+='<div class="fev k-'+s.kind+(s.log?' session-log':' session-log-off')+'"'+(s.log?' role="button" tabindex="0" data-session="'+i+'" title="View transcript · last 500 lines"':' title="Transcript unavailable · '+why+'"')+'><span class="ago">'+s.ago+'m</span><span class="kd">'+s.kind+'</span><span class="'+cls+'" style="flex:1;overflow:hidden;text-overflow:ellipsis">'+esc(label)+'</span>'+(s.peak?'<span style="color:#46566a">'+fmtKiB(s.peak)+'</span>':'')+'<span style="color:#46566a">'+fmtDur(s.dur)+'</span><span class="transcript">'+(s.log?'▤ transcript':'— '+why)+'</span></div>';});
  sh+='</div>';
  var floorEvents=d.floorEvents||[],limitDropped=d.limitDropped||0;
  if(floorEvents.length||limitDropped){
    sh+='<div class="limitfeed"><div>OPERATING LIMIT EVENTS</div>';
    floorEvents.forEach(function(e){sh+='<div class="lev"><span class="sev-'+(e.severity==="error"?"error":"warn")+'">'+esc(e.severity.toUpperCase())+'</span><span>'+esc(e.name)+' '+e.measured+'/'+e.limit+' · '+esc(e.subject)+' · '+esc(e.cause)+'</span></div>';});
    if(limitDropped)sh+='<div class="drop">'+limitDropped+' older event'+(limitDropped===1?'':'s')+' dropped by retention</div>';
    sh+='</div>';
  }
  document.getElementById("w-sessions").innerHTML=sh;
  document.getElementById("dfeed").addEventListener("click",function(e){var row=e.target.closest("[data-session]");if(row){var s=d.sessions[Number(row.dataset.session)];if(s&&s.log)openLogs(BOX,s.log,s);}});
  document.getElementById("dfeed").addEventListener("keydown",function(e){if(e.key!=="Enter"&&e.key!==" ")return;var row=e.target.closest("[data-session]");if(row){e.preventDefault();row.click();}});
  document.getElementById("c-target").textContent="▸ MESSAGE "+id;
  var ci=document.getElementById("c-in");if(ci)ci.placeholder="Send a prompt to "+id+"…";
  /* Follows d.paused, not the working state: an idle but unpaused box was
     offering "Resume" while its click correctly sent `pause`. */
  document.getElementById("a-pause").textContent=(LIVE&&d.paused)||(!LIVE&&!work)?"▶ Resume":"⏸ Pause";
}
function updateCurrent(){if(VIEW!=="room"||STATE!=="working")return;var d=dataOf(BOX,ROOM);var el=document.getElementById("cur-el");if(!el)return;
  /* A stuck box is still STATE==="working" and may still have a d.cur, so
     without this branch the per-second tick overwrote the red held-duration
     with the session's own elapsed time — quietly restoring the healthy-
     looking readout the STUCK panel exists to replace. Keep counting, but
     count the thing that is wrong. */
  if(LIVE&&d.lock&&d.lock.stuck){el.textContent=fmtDur(d.lock.held+Math.floor((Date.now()-LASTPOLL)/1000));return;}
  if(!d.cur)return;el.textContent=fmtDur(Math.floor(Date.now()/1000)-d.cur.start);}
/* The STUCK panel's sub-line, and it NAMES THE BOUND (#610). An age alone
   cannot tell an operator a wedge from a threshold somebody raised: "held 62m"
   is alarming until you know the lane was entitled to 60, and it is nothing at
   all until you know it was entitled to 10. The bound came from the collector
   with the verdict — `units.stuck_verdict` decided both — so the page spells no
   threshold of its own here, the rule this file already follows for
   `ping.wedged`.

   Three shapes, matching the three the collector's own note has, because the
   note and the panel are read by the same operator about the same box:
     · a ceiling was declared — name the lane and its ceiling
     · nothing in flight — say so, and name STUCK_AFTER_S
     · in flight, ceiling unknown (a box older than the `timeout=` token) —
       today's sentence unchanged, because there is no bound to name that the
       box has told us about. */
function stuckLine(d){
  var head='STUCK · lock held '+fmtDur(d.lock.held);
  var tail=d.cur?' · '+esc(d.kind)+' '+esc(d.cur.key):'';
  if(d.lock.ceiling)return head+' · past the '+esc(d.cur?d.cur.kind:"session")+' ceiling of '+fmtDur(d.lock.ceiling)+tail;
  if(!d.cur&&d.lock.bound)return head+' · no session in flight, past '+fmtDur(d.lock.bound);
  return head+tail;
}
function mrow(k,v){return '<div class="mrow"><span class="mk">'+k+'</span><span class="mvv">'+v+'</span></div>';}
/* --- credential + heartbeat rendering -----------------------------------
   THREE credential states, not two. The probe stopped answering `ok` when it
   stopped testing credentials: it now reports what the duty engine last
   observed, and "no failure has been reported" is not the same claim as "I
   just checked and it works". Collapsing them back into a tick/cross here
   would put the lie straight back on screen — and rendering anything that is
   not the string "ok" as a cross (which this did) marked every healthy box
   as logged out the moment the vocabulary changed. */
function credGlyph(label,v){
  if(v==="flowing")return label+" ✓";
  if(v==="missing")return label+" ✗";
  /* stale: the engine is installed but not ticking, so nothing has been able
     to find out. Distinct from unknown (never installed) and emphatically
     distinct from ✓ — a disarmed box with a dead token used to render a tick
     here, which is the single most misleading thing this panel could say. */
  if(v==="stale")return label+" ~";
  /* waiting: hired, armed, and no tick has happened YET — distinct from stale,
     which claims we used to hear from this box. The operator's action differs:
     stale is "go find out why it stopped", waiting is "wait one tick boundary".
     Rendering them alike told a minute-old hire it had gone silent (#265). */
  if(v==="waiting")return label+" …";
  return label+" ?";               /* unknown: no engine has run, so nothing is known */
}
/* The engine's INTEGRITY, rendered beside the version it claims (#159, #190).
   The version alone is what install.sh wrote once; this is what the files on
   the box hash to NOW, so a hand-edited engine says so here instead of showing
   its shipped stamp forever. "Is my fleet running what I think it is?" was made
   answerable by #159 and the answer never reached the operator looking at this
   page.
   The VERDICT, never the build provenance. stampVersion() strips `crew@` and
   the commit on purpose and the walk asserts they stay stripped; rendering the
   stamp here would red that check and tell the operator nothing about whether
   the tree still matches it.
   The words are `crew status`'s INTEGRITY column verbatim, not synonyms: a CLI
   and a floor holding private vocabularies for one fact is what #38 was filed
   about, and MODIFIED shouts here for the reason it shouts there — it is the
   one value an operator must not skim past.
   "" is a box that did not answer (a probe that could not run), and renders
   nothing: an unhired box has no engine line at all, and an engine too old to
   carry the tool still answers `unverified`. */
function integrityMark(v){
  if(v==="current")return '<span class="ig" style="color:#5fce9b" title="every engine file is what the recorded install shipped">✓ current</span>';
  if(v==="modified")return '<span class="ig" style="color:#ff5147" title="the engine files diverge from the recorded install — crew status names them">⚠ MODIFIED</span>';
  if(v==="unverified")return '<span class="ig" style="color:#f7bd4e" title="no readable manifest: hired before content stamping, or by another format — the next crew upgrade records one">~ unverified</span>';
  return "";
}
function credColour(d){
  if(d.gh==="missing"||d.vendor==="missing")return "#ff5147";
  if(d.gh==="flowing"&&d.vendor==="flowing")return "#5fce9b";
  /* stale, waiting or unknown: not established, not green. `waiting` shares the
     amber deliberately — a box we have not heard from yet has not proved its
     credentials work, and green is a claim only a completed tick can support. */
  return "#f7bd4e";
}
/* The ping tier. `null` means this collector never reported one — an older
   floor.py, or a box it skipped because it is stopped — and must read as "—",
   never as a failure. */
function pingText(d){
  if(!LIVE)return "—";
  if(!d.ping)return "—";
  /* Stale outranks ok: the tier has not run recently enough for its last
     answer to be a claim about now, and showing "8ms · ok" from an arbitrarily
     old round is stale green on a liveness widget — the exact thing this tier
     was added to prevent. */
  if(d.ping.stale)return "stale · "+fmtDur(d.ping.age)+" old";
  if(d.ping.ok)return d.ping.ms+"ms · "+d.ping.age+"s ago";
  return "no answer · "+d.ping.fails+" missed";
}
function pingColour(d){
  if(!LIVE||!d.ping)return "#46566a";
  if(d.ping.stale)return "#f7bd4e";   /* amber: unknown, not green and not red */
  return d.ping.ok?"#5fce9b":"#ff5147";
}
/* Access-panel button: live ones are real, demo ones keep the .woff tooltip
   that says why they do nothing. */
function ab(id,label){return '<button class="lbtn'+(LIVE?'':' woff')+'" id="'+id+'"'+(LIVE?'':' title="'+CTL_TIP+'"')+'>'+label+'</button>';}
/* unreachableBox DATA — has this box stopped answering, for the WORDS on a
   control (#486). The collector decides what actually happens: floor/fleet.py's
   wedged() is the rule, restart asks it there, and `ping.wedged` is that same
   answer served. So this is not the page's opinion of the same evidence — it
   is the collector's verdict, which is the only way the confirm an operator
   reads can be a promise about the path the host will take.

   Re-deriving it here from the miss count and a constant of our own was the
   first shape and it was wrong: a page-side 3 against a configurable
   `CREW_FLOOR_PING_FAILS` meant that at a threshold of 2 — what this repo's
   own suite runs — the collector force-stopped a guest the dialog described
   as a graceful restart. Staleness is folded into wedged() for the same
   reason it belongs there: a tier that has not run recently is unmeasured,
   and "about to be killed" is the one direction this sentence must not be
   wrong in. One rule, one place, one answer on the wire. */
function unreachableBox(d){return !!(LIVE&&d&&d.ping&&d.ping.wedged);}
/* restartPlan — the confirm text for Restart, which is one control with two
   paths, AND the mode that text promised, from ONE evaluation of the verdict.

   Naming only the gentle path would be the "graceful stop that silently became
   a force stop" #486 D1 refuses, moved from the code into the sentence. But
   the sentence alone cannot keep that promise: this fleet snapshot is up to
   one poll old (POLL_MS), and the collector re-reads the ping map when the
   POST lands. A box crossing the wedge boundary in that window let an operator
   confirm the gentle sentence over a host that then ran `stop --force` — one
   rule, still, but evaluated at two times, which is two answers.

   So `mode` rides along on the request as the operator's AUTHORISATION: not an
   instruction to the collector, which still decides for itself, but a record
   of which sentence was on screen. The collector compares the two and refuses
   if they disagree, having fired nothing. Both fields come out of one `u`
   here for the reason the whole round exists — read the verdict twice and the
   words and the mode could themselves drift apart. */
function restartPlan(box,d){var u=unreachableBox(d);return{mode:u?"force":"graceful",
  ask:u
  ?"Restart "+box+"? It has stopped answering, so it is FORCE-STOPPED — killed outright — and then started. Any running session is lost."
  :"Restart "+box+"? It is stopped and started again."};}
/* Ask, then fire what was asked. One helper so both entry points — the access
   panel and the detail view — cannot drift into posting different bodies. */
function restartClick(box,d){var p=restartPlan(box,d);if(confirm(p.ask))cmd("restart",{box:box,mode:p.mode});}
function buildOps(){var list=document.getElementById("opslist");if(!list)return;var working=ROSTER.filter(function(u){return u.state==="working"&&dataOf(UNITID(u),u.room).cur;});
  var cc=document.getElementById("ops-count");if(cc)cc.textContent="· "+working.length;
  list.innerHTML=working.length?working.map(function(u){var d=dataOf(UNITID(u),u.room),vc=VENDORCOL(u.agent),kc=u.room==="builder"?"#f7bd4e":u.room==="reviewer"?"#5cb4ff":"#c98bff";
    return '<div class="op"><span class="u" style="color:'+vc+'">'+esc(u.box||(u.agent+"-"+u.room))+'</span><span class="kd" style="color:'+kc+';background:'+hexA(kc,0.13)+'">'+esc(d.kind)+'</span><span class="tk">'+esc(d.cur.key)+'</span><span class="el" data-s="'+d.cur.start+'">'+fmtDur(Math.floor(Date.now()/1000)-d.cur.start)+'</span></div>';}).join(''):'<div style="color:#46566a;font-family:var(--mono);font-size:11px;padding:4px 0">— no active sessions —</div>';
  var fm=fleetMetric(),mr=document.getElementById("metrows");if(mr)mr.innerHTML=mrow("Longest build",fmtDur(fm.build))+mrow("Longest review",fmtDur(fm.review))+mrow("Longest triage",fmtDur(fm.triage))+mrow("Avg session",fmtDur(fm.avg));}
function tickOps(){if(VIEW!=="floor")return;var now=Math.floor(Date.now()/1000);[].forEach.call(document.querySelectorAll("#opslist .el"),function(e){e.textContent=fmtDur(now-(+e.dataset.s));});}
/* DEMO ticker: synthetic duty.log traffic so the floor reads as a live system
   when there is no collector. In LIVE mode liveTicker() replaces it with the
   real SESSION lines each poll brings back. */
function tickerEvent(){if(VIEW!=="floor"||LIVE)return;var alive=ROSTER.filter(function(u){return u.state!=="offline";});if(!alive.length)return;var u=alive[ri2(0,alive.length-1)],kind=kindOf(u.room),start=Math.random()<0.5,msg,cls="";
  if(start){var key=kind==="triage"?"board":REPONAMES[ri2(0,5)]+"#"+ri2(11,148);msg="SESSION START kind="+kind+" key="+key;}
  else{var rc=Math.random()<0.12?1:0,out=rc?"aborted (budget)":outcomeFor(kind);msg="SESSION END kind="+kind+" rc="+rc+" outcome="+out;cls=rc?"cr":"ok";}
  var s=document.getElementById("stream");if(!s)return;var el=document.createElement("div");el.className="l";var m=msg;if(cls==="ok")m=msg.replace(/(outcome=[^\s]+.*)$/,'<span class="ok">$1</span>');if(cls==="cr")m=msg.replace(/rc=1/,'<span class="cr">rc=1</span>');
  el.innerHTML='<span class="tt">'+clockStr()+'</span><span class="u" style="color:'+VENDORCOL(u.agent)+'">'+u.agent+'-'+u.room+'</span><span class="m">'+m+'</span>';
  s.appendChild(el);while(s.childNodes.length>30)s.removeChild(s.firstChild);s.scrollTop=s.scrollHeight;}

/* ===================== HERO ROBOT (heavy armored builder) ===================== */
/* Modelling light — the one pass that makes these read as volumes.
   Every unit is assembled out of plate() calls, and plate() is a two-stop
   vertical gradient fitted to each polygon's own bounding box. So a pauldron
   and a boot were lit identically: each got its own private little sky. The
   result is a body where no surface is brighter for being higher or nearer the
   lamp, which is exactly the recipe for a flat cut-out — and it is why the rim
   light has been carrying all of the separation on its own since loop 6.
   One pass in body space, source-atop so it lands only on the silhouette:
   the lamp is directly overhead (LAMPX === ROBOX), so upper surfaces gain, the
   recess under the chest and between the legs loses, and the deck throws a
   cool bounce back onto the lowest quarter. Deliberately not per-agent — this
   is the ROOM's light, and it has no opinion about who is standing in it. */
function modelLight(offl){
  var k=offl?0.4:1;
  RB.save();RB.globalCompositeOperation="source-atop";
  var key=RB.createLinearGradient(0,150,0,470);
  key.addColorStop(0,"rgba(206,226,255,"+(0.125*k)+")");
  key.addColorStop(0.30,"rgba(186,206,238,"+(0.045*k)+")");
  key.addColorStop(0.68,"rgba(2,6,14,0.10)");
  key.addColorStop(1,"rgba(2,6,14,"+(0.20+0.06*(1-k))+")");
  RB.fillStyle=key;RB.fillRect(0,0,RW,RH);
  // deck bounce: cool, weak, and only on what is close enough to the floor
  var bnc=RB.createLinearGradient(0,RH-142,0,RH-12);
  bnc.addColorStop(0,"rgba(104,146,196,0)");
  bnc.addColorStop(1,"rgba(104,146,196,"+(0.105*k)+")");
  RB.fillStyle=bnc;RB.fillRect(0,0,RW,RH);
  RB.restore();
}
/* Cavity occlusion. modelLight (loop 11) is a sky: it knows how high a surface
   sits and nothing about what is directly above it. So a chest plate that
   overhangs an abdomen by 8cm, a helmet sitting on a collar, a bezel standing
   proud of the glass it surrounds — every one of those joins stayed open, and
   an overhang that casts nothing reads as a decal on a flat panel rather than
   as a part in front of another part. This is the short-range half of the same
   light: a hard falloff a few pixels deep, immediately under whatever is in
   front. It is the cheapest possible ambient occlusion and it is what makes
   the difference between layered and printed. */
function cavity(c,x,y,w,h,a){
  var cg3=c.createLinearGradient(0,y,0,y+h);
  cg3.addColorStop(0,"rgba(2,5,10,"+a+")");
  cg3.addColorStop(0.55,"rgba(2,5,10,"+(a*0.34)+")");
  cg3.addColorStop(1,"rgba(2,5,10,0)");
  c.fillStyle=cg3;c.fillRect(x,y,w,h);
}
function buildRobo(t,st){
  var info=AGENT==="codex"?buildCodex(t,st):AGENT==="grok"?buildGrok(t,st):AGENT==="kimi"?buildKimi(t,st):buildClaude(t,st);
  /* Here rather than in drawRobot, because camStill renders the god-view
     portraits through this same function and would otherwise show four units
     lit differently from the four in the console. */
  modelLight(st==="offline");
  return info;
}
/* The rim light — the bright hairline down each unit's edges, and the single
   biggest thing separating it from the room behind it.
   It was ONE gradient, warm on the left and cyan on the right, for all four
   units. Which meant the fleet's four vendor colours existed only in lights
   and screens: switch a claude for a kimi and the outline of the thing was
   identical. The rim is a large, always-visible surface and it was saying
   nothing about who this was.
   Now the KEY side carries the vendor's own colour and the fill side keeps the
   room's cool bounce, so each unit is identifiable from its edge alone — which
   is the only part of it that survives at grid-cell size. */
function buildRim(vend){
  var V=vend||[255,170,90];
  /* Pixel ops, so this one runs in PHYSICAL space: the self-copy must be 1:1
     whatever SS is, and the hairline offsets and gradient span scale by SS
     explicitly so the rim wears the same sprite-relative width at every
     sampling density. */
  RR.setTransform(1,0,0,1,0,0);
  RR.globalCompositeOperation="source-over";RR.drawImage(robo,0,0);
  RR.globalCompositeOperation="destination-out";RR.drawImage(robo,-2.4*SS,1.8*SS);RR.drawImage(robo,-1.6*SS,-2.6*SS);
  RR.globalCompositeOperation="source-in";
  var rg=RR.createLinearGradient(70*SS,0,450*SS,0);
  rg.addColorStop(0,rgba(V[0],V[1],V[2],0.95));
  rg.addColorStop(0.42,rgba((V[0]+150)/2,(V[1]+175)/2,(V[2]+205)/2,0.45));
  rg.addColorStop(1,rgba(95,214,255,1));
  RR.fillStyle=rg;RR.fillRect(0,0,RW*SS,RH*SS);RR.globalCompositeOperation="source-over";
  RR.setTransform(SS,0,0,SS,0,0);
}
function buildClaude(t,st){
  var offl=st==="offline",work=st==="working";
  var ctxs=[RB,RE,RR];for(var i=0;i<3;i++){var c=ctxs[i];c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,c.canvas.width,c.canvas.height);c.setTransform(SS,0,0,SS,0,0);c.globalAlpha=1;c.globalCompositeOperation="source-over";c.filter="none";}
  var cx=260,gyf=560;
  var breath=(reduced||offl)?0:Math.sin(t*1.4)*2.0;
  var sT="#242e3d",sM="#131a25",sB="#080c13",ed="#2c3648",eH="#41506a",rc="#05080d";
  if(offl){sT="#181d25",sM="#0e131b",sB="#05080d",ed="#222932",eH="#2a323d";}
  var acc=offl?"#2b3038":"#ff9a3c", accH=offl?"#3a414c":"#ffca80", accL=offl?"#1c2129":"#a8500f";
  var corePulse=offl?0:(work?(0.58+0.2*Math.sin(t*7)):(0.32+0.15*Math.sin(t*2)));
  var g=RB;

  function em(c,fn){fn(c);} // draw emissive on given ctx
  function accGlow(c,x,y,w,h){ if(offl)return; var gg=c.createLinearGradient(0,y,0,y+h);gg.addColorStop(0,rgba(255,180,90,0.9));gg.addColorStop(1,rgba(200,90,20,0.9));c.fillStyle=gg;rr(c,x,y,w,h,1);c.fill(); }
  // grime weeping from a bolt: albedo, so it does not dim with power state
  function weep(x,y,len){g.fillStyle="rgba(70,44,24,0.30)";
    poly(g,[[x-1.2,y+2],[x+1.2,y+2],[x+0.6,y+len],[x-0.6,y+len]]);g.fill();}

  /* ---------- BACK: cables, nothing else ----------
     The heat-sink plate went first (from the front, the gap between torso
     and arm IS the drawing) and the exhaust stacks went next, on the same
     verdict: hardware standing above the shoulders read as luggage. What
     hangs there now is slack — two power cables per side looping out of the
     back and down into the collar, drawn before everything so the torso and
     pauldrons overlap them. Doom units don't carry backpacks; they trail
     cables. */
  [[-1],[1]].forEach(function(k){var s=k[0];
    [[54,66,184,20,6],[40,48,198,10,4.5]].forEach(function(cb){
      var x0=cx+s*cb[0], mx2=cx+s*cb[1], my2=cb[2]+breath, x1=cx+s*cb[3], y1=212+breath;
      g.strokeStyle="#05080e";g.lineWidth=cb[4];g.beginPath();
      g.moveTo(x0,252+breath);g.quadraticCurveTo(mx2,my2,x1,y1);g.stroke();
      g.strokeStyle=offl?"#2c3440":"#5b6c85";g.lineWidth=1.4;g.beginPath();
      g.moveTo(x0,252+breath);g.quadraticCurveTo(mx2,my2,x1,y1);g.stroke();});});

  // ---------- LEGS (mirror) ----------
  function leg(sgn){
    var lx=cx+sgn*30;
    // boot
    plate(g,[[lx-24,520+breath*0.2],[lx+20,520+breath*0.2],[lx+26,560],[lx-30,560]],sT,sB,ed);
    plate(g,[[lx-30,552],[lx+26,552],[lx+26,560],[lx-30,560]],"#0c1119","#03050a",null);
    // shin + hydraulic
    plate(g,[[lx-18,452+breath*0.4],[lx+18,452+breath*0.4],[lx+22,522],[lx-22,522]],sM,sB,ed);
    pl(g,lx+sgn*20,470,lx+sgn*20,516,"#0a0f18",5); pl(g,lx+sgn*20,470,lx+sgn*20,516,eH,1.4);
    // knee guard
    plate(g,[[lx-20,436+breath*0.5],[lx+20,436+breath*0.5],[lx+18,462],[lx-18,462]],sT,sM,ed);
    [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(255,150,70,0.8);c.fillRect(lx-4,446,8,3);}});
    // thigh
    plate(g,[[lx-22,360+breath*0.7],[lx+24,360+breath*0.7],[lx+20,440+breath*0.4],[lx-20,440+breath*0.4]],sM,sB,ed);
    pl(g,lx-10,372+breath*0.7,lx-8,432,rc,1);
    /* BATTLE THREE. Something with claws got the right thigh and lost the
       exchange: three parallel rakes, dark trenches with bright torn lips,
       ending where they end because that is where it stopped. */
    if(sgn>0)for(var rk=0;rk<3;rk++){var rx=lx-10+rk*8;
      pl(g,rx,364+breath*0.7,rx+13,389+breath*0.6,"rgba(4,8,14,0.6)",2);
      pl(g,rx+0.5,363+breath*0.7,rx+13.5,388+breath*0.6,"rgba(170,192,222,"+(offl?0.12:0.32)+")",0.9);}
  }
  leg(-1);leg(1);

  // ---------- PELVIS ----------
  plate(g,[[cx-34,342+breath],[cx+34,342+breath],[cx+30,378+breath*0.8],[cx-30,378+breath*0.8]],sT,sB,ed);
  // tassets
  plate(g,[[cx-40,344+breath],[cx-20,344+breath],[cx-24,382+breath*0.8],[cx-44,380+breath*0.8]],sM,sB,ed);
  plate(g,[[cx+20,344+breath],[cx+40,344+breath],[cx+44,380+breath*0.8],[cx+24,382+breath*0.8]],sM,sB,ed);
  /* The girdle centre was a glowing stripe painted straight onto the pelvis.
     Now the belt closes through a bolted buckle housing that bridges the
     waist gap, and the codpiece is its own pointed plate — doom loincloth,
     bolted at the corners — with the accent glow recessed into a slot in it
     rather than resting on top. */
  plate(g,[[cx-12,338+breath],[cx+12,338+breath],[cx+10,354+breath*0.9],[cx-10,354+breath*0.9]],sT,sB,ed);
  rivet(g,cx-7,344+breath,eH);rivet(g,cx+7,344+breath,eH);
  plate(g,[[cx-9,350+breath*0.9],[cx+9,350+breath*0.9],[cx+7,372+breath*0.8],[cx,384+breath*0.8],[cx-7,372+breath*0.8]],sM,sB,ed);
  g.fillStyle="rgba(0,0,0,0.30)";g.fillRect(cx-8,351+breath*0.9,16,3); // buckle's shade on the plate below it
  rivet(g,cx-5,368+breath*0.8,eH);rivet(g,cx+5,368+breath*0.8,eH);
  g.fillStyle="#03060c";g.fillRect(cx-3,354+breath*0.9,6,18);
  [RB,RE].forEach(function(c){accGlow(c,cx-2,355+breath*0.9,4,16);});

  /* ---------- ABDOMEN: the join you can see into ----------
     Two clean trapezoids used to butt the chest onto the pelvis, which is why
     the torso read as one casting. The waist is where a machine admits it is
     several machines: a dark spine cavity with twin pistons and a power
     conduit, and the armour is two STAGGERED belt plates — one long to the
     left, one long to the right — bolted over it, so the seams never line up
     the way a moulded shell's would. */
  g.fillStyle="#02040a";poly(g,[[cx-18,300+breath],[cx+18,300+breath],[cx+15,345+breath],[cx-15,345+breath]]);g.fill();
  [-1,1].forEach(function(sp){var px=cx+sp*9;
    pl(g,px,302+breath,px,343+breath,"#0a0f18",4.5);
    pl(g,px-1,302+breath,px-1,343+breath,offl?"#333c48":"#7e94b2",1.2);});
  g.strokeStyle="#0a0f18";g.lineWidth=3.4;g.beginPath();
  g.moveTo(cx+15,306+breath);g.quadraticCurveTo(cx+25,324+breath,cx+13,344+breath);g.stroke();
  g.strokeStyle=offl?"#2b3038":"#a8500f";g.lineWidth=1.5;g.beginPath();
  g.moveTo(cx+15,306+breath);g.quadraticCurveTo(cx+25,324+breath,cx+13,344+breath);g.stroke();
  var ab1=307+breath, ab2=324+breath;
  plate(g,[[cx-30,ab1],[cx+20,ab1],[cx+27,ab1+5],[cx+24,ab1+14],[cx-26,ab1+14]],sM,sB,ed);
  plate(g,[[cx-20,ab2],[cx+30,ab2],[cx+26,ab2+14],[cx-24,ab2+14],[cx-27,ab2+5]],sM,sB,ed);
  rivet(g,cx+21,ab1+10,eH);rivet(g,cx-21,ab2+10,eH);
  // battle three's other souvenir: the belt chamfer took a hit and folded
  g.fillStyle="rgba(4,8,14,0.55)";poly(g,[[cx+21,ab1+4],[cx+27,ab1+6],[cx+24,ab1+12],[cx+19,ab1+9]]);g.fill();
  pl(g,cx+20,ab1+9,cx+25,ab1+6,"rgba(170,192,222,"+(offl?0.12:0.30)+")",1);
  g.strokeStyle="rgba(150,172,204,"+(offl?0.08:0.18)+")";g.lineWidth=1;
  g.beginPath();g.moveTo(cx-28,ab1+1);g.lineTo(cx+19,ab1+1);
  g.moveTo(cx-19,ab2+1);g.lineTo(cx+28,ab2+1);g.stroke();

  // ---------- CHEST (broad, angled) ----------
  plate(g,[[cx-58,300+breath],[cx-66,236+breath],[cx-34,214+breath],[cx+34,214+breath],[cx+66,236+breath],[cx+58,300+breath]],sT,sM,ed);
  // upper chest bevel highlight
  plate(g,[[cx-60,240+breath],[cx-32,220+breath],[cx+32,220+breath],[cx+60,240+breath],[cx+54,250+breath],[cx-54,250+breath]],"#2c3849","#1a2331",null);
  // side intake vents (glow)
  [[-48,-1],[48,1]].forEach(function(k){var vx=cx+k[0]-(k[1]<0?10:0);
    RB.fillStyle=rc;rr(RB,vx,256+breath,10,30,2);RB.fill();
    [RB,RE].forEach(function(c){for(var s=0;s<4;s++){if(!offl){c.fillStyle=rgba(255,150,70,0.7);c.fillRect(vx+2,260+breath+s*7,6,3);}}});
  });
  // panel lines + rivets on chest
  pl(g,cx-40,262+breath,cx+40,262+breath,rc,1);
  rivet(g,cx-52,246+breath,eH);rivet(g,cx+52,246+breath,eH);rivet(g,cx-48,292+breath,eH);rivet(g,cx+48,292+breath,eH);
  // scratches (battle wear)
  if(!offl){g.strokeStyle="rgba(120,140,170,0.25)";g.lineWidth=1;g.beginPath();g.moveTo(cx+14,244+breath);g.lineTo(cx+30,258+breath);g.moveTo(cx-24,270+breath);g.lineTo(cx-12,282+breath);g.stroke();}
  /* A service history. Every plate so far is the plate the unit shipped with,
     which is its own kind of factory-clean. One repair on the right pec: a
     patch of newer, bluer steel bolted over a scorch mark, weld stitches
     along its top edge where it was tacked before bolting. The patch edges
     deliberately align with nothing — repairs never do. */
  /* BATTLE ONE. Something split the left pec plate and the unit finished the
     job before anyone fixed it. The crack is rewelded — a jagged seam with
     stitch ticks — and a strap of newer steel is bolted ACROSS it, because a
     weld you strap is a weld you no longer worry about. Scar tissue as
     reinforcement: the left chest is now stronger than the plate it split
     from. */
  var ck=[[cx-53,244],[cx-46,252],[cx-49,258],[cx-40,264],[cx-42,270],[cx-34,275]];
  g.strokeStyle="rgba(4,8,14,0.65)";g.lineWidth=1.8;g.beginPath();
  g.moveTo(ck[0][0],ck[0][1]+breath);for(var c9=1;c9<ck.length;c9++)g.lineTo(ck[c9][0],ck[c9][1]+breath);g.stroke();
  g.strokeStyle="rgba(150,172,204,"+(offl?0.12:0.30)+")";g.lineWidth=1;g.beginPath();
  for(var w9=1;w9<ck.length;w9++){var mx9=(ck[w9][0]+ck[w9-1][0])/2,my9=(ck[w9][1]+ck[w9-1][1])/2+breath;
    g.moveTo(mx9-2.4,my9-2);g.lineTo(mx9+2.4,my9+2);}
  g.stroke();
  plate(g,[[cx-58,254+breath],[cx-36,260+breath],[cx-37,268+breath],[cx-59,262+breath]],
    offl?"#1f2732":"#2e3a4e",offl?"#10151d":"#182130",ed);
  rivet(g,cx-55,258+breath,eH);rivet(g,cx-40,264+breath,eH);
  var scorch=g.createRadialGradient(cx+37,278+breath,3,cx+37,278+breath,22);
  scorch.addColorStop(0,"rgba(8,6,5,0.5)");scorch.addColorStop(1,"rgba(8,6,5,0)");
  g.fillStyle=scorch;g.fillRect(cx+15,256+breath,44,44);
  plate(g,[[cx+26,268+breath],[cx+43,264+breath],[cx+46,288+breath],[cx+28,293+breath]],
    offl?"#1f2732":"#2e3a4e",offl?"#10151d":"#182130",ed);
  rivet(g,cx+29,270+breath,eH);rivet(g,cx+41,267+breath,eH);
  rivet(g,cx+43,285+breath,eH);rivet(g,cx+31,289+breath,eH);
  g.strokeStyle="rgba(150,172,204,"+(offl?0.14:0.34)+")";g.lineWidth=1.1;g.beginPath();
  for(var wd=0;wd<5;wd++){var wx=cx+27.5+wd*3.6,wy=267.6+breath-wd*0.85;
    g.moveTo(wx,wy-1.8);g.lineTo(wx+1.6,wy+1.8);}
  g.stroke();
  /* Stencilled unit marking, and paint worn off the plate edges.
     A fleet vehicle carries its designation, and every plate on this model met
     its neighbour at a perfectly clean line — which is what made a heavy mech
     read as a rendered solid rather than as something assembled out of parts
     that have been knocked about. Geometric, not text: at grid-cell size the
     chest is 12px across, so a glyph would be mush, but a stencil BLOCK still
     reads as a marking. */
  g.save();g.globalAlpha=offl?0.25:0.5;
  g.fillStyle="#c9a227";g.fillRect(cx-46,272+breath,3,12);g.fillRect(cx-40,272+breath,3,12);
  g.fillStyle="rgba(201,162,39,0.6)";g.fillRect(cx-46,286+breath,9,2);
  // the tally: one stroke per battle walked away from, same paint as the marking
  for(var tl=0;tl<3;tl++)g.fillRect(cx-46+tl*4,291+breath,2,7);
  g.restore();
  // nicks: paint gone from the lips that lead. Constants, not noise — a nick
  // is a place, and it stays where it happened.
  g.strokeStyle="rgba(190,208,232,"+(offl?0.14:0.34)+")";g.lineWidth=1.6;g.beginPath();
  [[-20],[-2],[25]].forEach(function(nk){g.moveTo(cx+nk[0],218.6+breath);g.lineTo(cx+nk[0]+2.4,221+breath);});
  g.stroke();
  // worn edges: a bright hairline along the top lip of each big plate
  g.strokeStyle="rgba(150,172,204,"+(offl?0.10:0.22)+")";g.lineWidth=1;
  g.beginPath();g.moveTo(cx-32,220+breath);g.lineTo(cx+32,220+breath);
  g.moveTo(cx-28,306+breath);g.lineTo(cx+28,306+breath);
  g.moveTo(cx-30,344+breath);g.lineTo(cx+30,344+breath);g.stroke();
  // the bevel band sits ON the pecs: contact shadow under its lower edge,
  // and the bolts it is torqued down by have been weeping into the paint
  pl(g,cx-52,251.5+breath,cx+52,251.5+breath,"rgba(0,0,0,0.30)",2);
  weep(cx-48,292+breath,11);weep(cx+48,292+breath,11);weep(cx+31,289+breath,8);
  /* Sternum housing and collarbone struts.
     The reactor was a lit circle cut into a flat slab: the single largest
     surface on the unit was one polygon, and the brightest thing on it had no
     mounting. Once the modelling light landed, that slab was the flattest
     region on any of the four. A raised centre housing gives the torso a third
     dimension — the chest now steps forward toward the viewer — and two struts
     from the collar to the shoulder joints explain how the arms are carried.
     Drawn before the core, so the core is set INTO this rather than onto it. */
  var stY=234+breath;
  plate(g,[[cx-30,stY+2],[cx-22,stY-10],[cx+22,stY-10],[cx+30,stY+2],[cx+27,stY+62],[cx-27,stY+62]],"#2b3648","#171f2c",ed);
  g.fillStyle="rgba(168,192,226,"+(offl?0.08:0.20)+")";
  poly(g,[[cx-22,stY-10],[cx+22,stY-10],[cx+30,stY+2],[cx-30,stY+2]]);g.fill();
  g.strokeStyle="rgba(4,8,14,0.55)";g.lineWidth=1.4;
  g.beginPath();g.moveTo(cx-30,stY+2);g.lineTo(cx-27,stY+62);g.moveTo(cx+30,stY+2);g.lineTo(cx+27,stY+62);g.stroke();
  [-1,1].forEach(function(sg3){                       // collarbone struts to the shoulders
    plate(g,[[cx+sg3*20,stY-8],[cx+sg3*30,stY-12],[cx+sg3*56,stY+6],[cx+sg3*50,stY+14]],sM,sB,ed);
    rivet(g,cx+sg3*48,stY+8,eH);});
  /* ---- REACTOR CORE (angular caged furnace) ----
     It was a lit circle behind thin pinstripes — a porthole. A reactor you
     would build armour around is an octagonal recess with bolted facets and
     two heavy cage bars in front of the fire, so the brightest thing on the
     unit is something the assembly visibly RESTRAINS. The bars are cut out of
     the emissive buffer too: bloom must leak around the cage, never through
     it. */
  var coreY=262+breath;
  function octo(c,r){poly(c,[[cx-r*0.45,coreY-r],[cx+r*0.45,coreY-r],[cx+r,coreY-r*0.45],[cx+r,coreY+r*0.45],[cx+r*0.45,coreY+r],[cx-r*0.45,coreY+r],[cx-r,coreY+r*0.45],[cx-r,coreY-r*0.45]]);}
  RB.fillStyle="#03060c";octo(RB,24);RB.fill();
  RB.strokeStyle=ed;RB.lineWidth=2;octo(RB,24);RB.stroke();
  // lamp catches the two upper facets of the recess lip
  RB.strokeStyle="rgba(150,174,208,"+(offl?0.10:0.30)+")";RB.lineWidth=1.4;
  RB.beginPath();RB.moveTo(cx-24,coreY-10.8);RB.lineTo(cx-10.8,coreY-24);RB.lineTo(cx+10.8,coreY-24);RB.stroke();
  rivet(RB,cx-17,coreY-17,eH);rivet(RB,cx+17,coreY-17,eH);
  rivet(RB,cx-17,coreY+17,eH);rivet(RB,cx+17,coreY+17,eH);
  [RB,RE].forEach(function(c){ if(offl){c.fillStyle="#161b22";c.beginPath();c.arc(cx,coreY,9,0,7);c.fill();return;}
    c.save();octo(c,21);c.clip();
    var cg=c.createRadialGradient(cx,coreY,1,cx,coreY,20);cg.addColorStop(0,rgba(255,225,160,corePulse));cg.addColorStop(0.4,rgba(255,150,60,0.7*corePulse));cg.addColorStop(1,"rgba(255,120,40,0)");c.fillStyle=cg;c.fillRect(cx-21,coreY-21,42,42);
    c.fillStyle=rgba(255,240,210,corePulse);c.beginPath();c.arc(cx,coreY,5,0,7);c.fill();
    c.restore(); });
  // the cage: two heavy bars in front of the fire, on body AND emissive
  [-8,8].forEach(function(bx4){
    RB.save();octo(RB,22);RB.clip();
    RB.strokeStyle="#0a0f18";RB.lineWidth=5;
    RB.beginPath();RB.moveTo(cx+bx4,coreY-22);RB.lineTo(cx+bx4,coreY+22);RB.stroke();
    RB.strokeStyle="rgba(150,174,208,"+(offl?0.08:0.22)+")";RB.lineWidth=1;
    RB.beginPath();RB.moveTo(cx+bx4-2,coreY-20);RB.lineTo(cx+bx4-2,coreY+20);RB.stroke();
    RB.restore();
    if(!offl){RE.save();RE.globalCompositeOperation="destination-out";
      RE.strokeStyle="rgba(0,0,0,1)";RE.lineWidth=5;
      RE.beginPath();RE.moveTo(cx+bx4,coreY-22);RE.lineTo(cx+bx4,coreY+22);RE.stroke();RE.restore();}});
  /* The core lights the chest it is set into. Every emissive on this model
     glowed into the bloom buffer and then lit nothing — a reactor bright
     enough to read across a room, sitting in plate armour that stayed the
     same colour as the shins. Additive on the BODY layer, not the emissive
     one: this is the light arriving on the plates, not more glow leaving. */
  if(!offl){RB.save();RB.globalCompositeOperation="lighter";
    var bounce=RB.createRadialGradient(cx,coreY,4,cx,coreY,86);
    bounce.addColorStop(0,rgba(255,150,60,0.30*corePulse));
    bounce.addColorStop(0.5,rgba(220,110,40,0.11*corePulse));
    bounce.addColorStop(1,"rgba(200,90,30,0)");
    RB.fillStyle=bounce;RB.beginPath();RB.arc(cx,coreY,86,0,7);RB.fill();RB.restore();}

  // ---------- COLLAR / NECK ----------
  plate(g,[[cx-30,214+breath],[cx+30,214+breath],[cx+22,226+breath],[cx-22,226+breath]],sT,sM,ed);
  plate(g,[[cx-10,206+breath],[cx+10,206+breath],[cx+8,220+breath],[cx-8,220+breath]],sM,sB,null);
  // neck bearing: the ring the head actually turns on
  g.fillStyle="#04070d";g.beginPath();g.ellipse(cx,208+breath,13,4.5,0,0,7);g.fill();
  g.strokeStyle=ed;g.lineWidth=1.3;g.beginPath();g.ellipse(cx,208+breath,13,4.5,0,0,7);g.stroke();
  g.strokeStyle="rgba(150,174,208,"+(offl?0.10:0.30)+")";g.lineWidth=1.2;
  g.beginPath();g.ellipse(cx,208+breath,10,3.2,0,Math.PI*1.1,Math.PI*1.9);g.stroke();

  // ---------- ARMS (mirror; right arm can raise when working) ----------
  var handR;
  function arm(sgn,mode){
    var shx=cx+sgn*62, shy=244+breath;
    /* Shoulder ASSEMBLY, not shoulder decoration. The pauldron was two stacked
       slabs hanging in the air beside the chest — nothing said how the arm was
       attached, and the same dx offsets were used unmirrored so neither slab
       even faced its own side. Now the joint is a machine: a dark ball socket
       the arm hangs from, a piston running down into the upper arm, and the
       pauldron bolted OVER all of it as armour — mirrored properly, with a
       hard outer spike so the silhouette reads doom-plate instead of pillow. */
    function P(pts){return pts.map(function(p){return [shx+sgn*p[0],shy+p[1]];});}
    // ball socket first, so the pauldron overhangs it
    g.fillStyle="#04070d";g.beginPath();g.arc(shx,shy+8,10,0,7);g.fill();
    g.strokeStyle=ed;g.lineWidth=1.6;g.beginPath();g.arc(shx,shy+8,10,0,7);g.stroke();
    var sj=g.createRadialGradient(shx-3,shy+4,1,shx,shy+8,10);
    sj.addColorStop(0,"rgba(148,172,206,"+(offl?0.18:0.42)+")");
    sj.addColorStop(0.55,"rgba(56,68,88,0.5)");sj.addColorStop(1,"rgba(4,7,13,0.7)");
    g.fillStyle=sj;g.beginPath();g.arc(shx,shy+8,7.6,0,7);g.fill();
    /* No biceps plate. The upper arm was a grey trapezoid doing nothing but
       filling the space the backpack used to fill — same complaint, one limb
       down. The upper arm is now BARE MECHANISM: two exposed rods from the
       socket into the elbow, and the mass all lives in the forearm, which is
       where a machine that works with its hands would carry it. */
    pl(g,shx,shy+14,shx-sgn*2,shy+38,"#0a0f18",5);
    pl(g,shx,shy+14,shx-sgn*2,shy+38,offl?"#39424f":"#8fa6c4",1.6);
    // pauldron: one notched plate, outer edge dropping to a spike; the
    // underside is cut AROUND the socket so the joint visibly carries the arm
    plate(g,P([[-28,-22],[8,-32],[34,-20],[42,-2],[30,26],[14,12],[8,2],[-8,2],[-14,12],[-24,12]]),sT,sM,ed);
    // chamfer highlight along the crown, keyed to the lamp
    g.fillStyle="rgba(168,192,226,"+(offl?0.07:0.18)+")";
    poly(g,P([[-28,-22],[8,-32],[34,-20],[28,-14],[-24,-16]]));g.fill();
    // deep cut seam across the face + two bolts holding it to the socket arm
    pl(g,shx+sgn*30,shy-12,shx+sgn*36,shy+8,rc,1.4);
    rivet(g,shx-sgn*18,shy-4,eH);rivet(g,shx+sgn*20,shy+2,eH);
    if(sgn<0){ // one deep gouge across the left pauldron: dark trench, bright torn lip
      g.strokeStyle="rgba(4,8,14,0.6)";g.lineWidth=2.2;g.beginPath();
      g.moveTo(shx-18,shy-14);g.lineTo(shx+14,shy+2);g.stroke();
      g.strokeStyle="rgba(170,192,222,"+(offl?0.14:0.4)+")";g.lineWidth=1;g.beginPath();
      g.moveTo(shx-18,shy-15);g.lineTo(shx+14,shy+1);g.stroke();
      /* BATTLE TWO. A blast scorched this shoulder black; the answer was not
         paint. A cruder, heavier plate is welded over the burn — cut square
         in the field, three fat bolts, no chamfer anybody polished — and it
         half-buries the old gouge. The left shoulder now outweighs the
         right, and that asymmetry IS the record of the fight. */
      var bs2=g.createRadialGradient(shx+4,shy-8,3,shx+4,shy-8,24);
      bs2.addColorStop(0,"rgba(6,5,4,0.55)");bs2.addColorStop(1,"rgba(6,5,4,0)");
      g.fillStyle=bs2;g.fillRect(shx-20,shy-32,48,48);
      plate(g,[[shx-28,shy-24],[shx+4,shy-31],[shx+11,shy-9],[shx-20,shy-2]],
        offl?"#232c39":"#37455c",offl?"#11161f":"#1c2635",ed);
      [[shx-20,shy-17],[shx-5,shy-23],[shx+2,shy-10]].forEach(function(fb2){
        g.fillStyle="#0a0f18";g.beginPath();g.arc(fb2[0],fb2[1],2.6,0,7);g.fill();
        g.fillStyle=eH;g.beginPath();g.arc(fb2[0]-0.6,fb2[1]-0.6,1.3,0,7);g.fill();});}
    if(sgn>0){ // a bite out of the right spike: silhouette damage, cut to transparency
      g.save();g.globalCompositeOperation="destination-out";
      poly(g,[[shx+34,shy+2],[shx+44,shy+6],[shx+36,shy+15]]);g.fill();g.restore();
      g.strokeStyle="rgba(170,192,222,"+(offl?0.12:0.32)+")";g.lineWidth=1;
      g.beginPath();g.moveTo(shx+34,shy+2);g.lineTo(shx+36,shy+15);g.stroke();}
    // the pauldron sits ON the arm: contact shadow under its lower rim
    g.fillStyle="rgba(0,0,0,0.26)";
    poly(g,P([[-22,13],[-8,3],[8,3],[13,13],[7,21],[-18,21]]));g.fill();
    weep(shx-sgn*18,shy-3,9);
    // shoulder joint light, now sitting IN the socket
    [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(255,150,70,0.7);c.beginPath();c.arc(shx,shy+8,2.6,0,7);c.fill();}});
    /* The elbow, in the same joint language as the hips and knees: a dark
       ball, a lit crescent on the lamp side, a bolt through the middle. It
       caps the seam where upper arm meets forearm in every pose — before it,
       the two plates just touched, and the arm was the last limb whose bend
       had no mechanism. */
    function elbow(x,y){
      g.fillStyle="#04070d";g.beginPath();g.arc(x,y,6.5,0,7);g.fill();
      g.strokeStyle=ed;g.lineWidth=1.4;g.beginPath();g.arc(x,y,6.5,0,7);g.stroke();
      var eb=g.createRadialGradient(x-2,y-2,1,x,y,6.5);
      eb.addColorStop(0,"rgba(148,172,206,"+(offl?0.16:0.38)+")");
      eb.addColorStop(0.6,"rgba(56,68,88,0.5)");eb.addColorStop(1,"rgba(4,7,13,0.7)");
      g.fillStyle=eb;g.beginPath();g.arc(x,y,4.9,0,7);g.fill();
      rivet(g,x,y,eH);
    }
    /* The muscle. Every joint got its mechanism in earlier loops but nothing
       showed what MOVES the arm — the shoulder piston vanishes under the
       pauldron. One exposed actuator runs down the outer upper arm into the
       elbow in every pose: dark cylinder, bright rod, same language as the
       shin hydraulics. */
    /* The rods used to start at shy+26/+30 — well below the pauldron's rim
       at their x — so both hung in mid-air under the plate (operator caught
       it). They now start up in the socket's contact shadow and each is
       terminated by a clevis block, so the pair visibly hangs FROM the
       shoulder instead of floating beside it. */
    function actuator(x0,y0,x1,y1){
      pl(g,x0,y0,x1,y1,"#0a0f18",4.2);
      pl(g,x0,y0,x1,y1,offl?"#333c48":"#7e94b2",1.3);
      plate(g,[[x0-3.4,y0-3],[x0+3.4,y0-3],[x0+2.6,y0+2.6],[x0-2.6,y0+2.6]],"#151b27","#080c14","#242d3c");
      rivet(g,x0,y0-0.4,eH);}
    if(mode==='reachdown'){ // reach forward + down (welding pose)
      var ex=shx+sgn*8, ey=shy+42;
      actuator(shx+sgn*11,shy+18,ex+sgn*4,ey-4);
      actuator(shx-sgn*6,shy+21,ex-sgn*4,ey-4);
      var fx=ex - sgn*22, fy=ey+34;
      plate(g,[[ex-10,ey-2],[ex+10,ey],[fx+14,fy-4],[fx-10,fy-9]],sT,sM,ed);
      plate(g,[[fx-11,fy-9],[fx+15,fy-7],[fx+13,fy+13],[fx-13,fy+11]],sM,sB,ed); // gauntlet
      plate(g,[[fx-12,fy-4],[fx-19,fy+2],[fx-12,fy+8]],sM,sB,ed); // bracer fin, back edge
      rivet(g,fx-5,fy+4,eH);rivet(g,fx+7,fy+4,eH);
      plate(g,[[fx-2,fy+2],[fx+10,fy-3],[fx+14,fy+2],[fx+2,fy+9]],"#2a3444","#12181f","#3d4c63"); // torch
      elbow(ex,ey-1);
      handR={x:fx+13,y:fy+2};
    } else if(mode==='raiseup'){ // forearm raised, device held up in front of chest (inspect/dispatch)
      var ex3=shx+sgn*6, ey3=shy+40;
      actuator(shx+sgn*11,shy+18,ex3+sgn*4,ey3-4);
      actuator(shx-sgn*6,shy+21,ex3-sgn*4,ey3-4);
      var fx3=ex3 - sgn*26, fy3=ey3-32;   // forearm up + inward
      plate(g,[[ex3-10,ey3],[ex3+10,ey3-2],[fx3+14,fy3+6],[fx3-10,fy3-3]],sT,sM,ed);
      plate(g,[[fx3-11,fy3-7],[fx3+15,fy3-5],[fx3+13,fy3+15],[fx3-13,fy3+13]],sM,sB,ed); // gauntlet
      plate(g,[[fx3+14,fy3],[fx3+21,fy3+6],[fx3+14,fy3+12]],sM,sB,ed); // bracer fin, back edge
      rivet(g,fx3-4,fy3+8,eH);rivet(g,fx3+7,fy3+8,eH);
      elbow(ex3,ey3-1);
      if(sgn>0)handR={x:fx3+2,y:fy3+4};
    } else {
      var ex2=shx+sgn*4, ey2=shy+56;
      actuator(shx+sgn*11,shy+18,ex2+sgn*5,ey2-8);
      actuator(shx-sgn*6,shy+21,ex2-sgn*4,ey2-8);
      /* The forearm is a CONE, not a slab: narrow where it leaves the elbow,
         widening all the way to the wrist, blade fin off the outer flare —
         all the arm's mass hangs low, over the fists. */
      function ox(d){return ex2+sgn*d;}
      plate(g,[[ox(-11),ey2-2],[ox(11),ey2-2],[ox(20),ey2+30],[ox(18),ey2+56],[ox(-18),ey2+56],[ox(-16),ey2+32]],sT,sM,ed);
      plate(g,[[ox(16),ey2+10],[ox(26),ey2+22],[ox(19),ey2+34]],sM,sB,ed);
      pl(g,ox(11),ey2-2,ox(20),ey2+30,"rgba(150,172,204,"+(offl?0.10:0.26)+")",1.1);
      pl(g,ox(-7),ey2+10,ox(-9),ey2+50,rc,1);
      // power slot cut into the bracer face — the arm's one warm light
      g.fillStyle="#03060c";g.fillRect(ox(4)-2,ey2+16,4.5,24);
      [RB,RE].forEach(function(c){accGlow(c,ox(4)-1.2,ey2+18,2.8,20);});
      // wrist clamp: the gauntlet is a separate piece, banded on
      plate(g,[[ex2-19,ey2+42],[ex2+19,ey2+42],[ex2+18,ey2+50],[ex2-18,ey2+50]],sT,sM,ed);
      rivet(g,ex2-12,ey2+46,eH);rivet(g,ex2+12,ey2+46,eH);
      plate(g,[[ex2-16,ey2+56],[ex2+16,ey2+56],[ex2+13,ey2+76],[ex2-13,ey2+76]],sM,sB,ed);
      // knuckle cuts, so the fist is fingers and not a brick
      for(var kn=0;kn<3;kn++)pl(g,ex2-8+kn*8,ey2+60,ex2-8+kn*8,ey2+69,rc,1.2);
      g.strokeStyle="rgba(150,172,204,"+(offl?0.10:0.24)+")";g.lineWidth=1;
      g.beginPath();g.moveTo(ex2-13,ey2+58);g.lineTo(ex2+13,ey2+58);g.stroke();
      elbow(ex2,ey2-1);
      // joint light rides the elbow cap
      [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(255,150,70,0.6);c.beginPath();c.arc(ex2,ey2-1,1.8,0,7);c.fill();}});
      if(sgn>0)handR={x:ex2,y:ey2+64};
    }
  }
  arm(-1,'down');
  arm(1, work ? (ROOM==="builder"?'reachdown':'raiseup') : 'down');
  // room-specific handheld device for the raised-arm roles
  if(work&&ROOM!=="builder"&&handR){var h=handR;
    if(ROOM==="reviewer"){ plate(g,[[h.x-3,h.y-9],[h.x+17,h.y-11],[h.x+17,h.y+2],[h.x-3,h.y+4]],"#1a2836","#0c1620","#3a5570");
      [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(130,205,255,0.75);c.fillRect(h.x+1,h.y-7,11,7);}}); }
    else { plate(g,[[h.x-2,h.y-11],[h.x+9,h.y-13],[h.x+12,h.y+4],[h.x+1,h.y+6]],"#241a30","#140e1c","#4a3a5e");
      [RB,RE].forEach(function(c){if(!offl){c.fillStyle=rgba(201,139,255,0.75);c.fillRect(h.x+2,h.y-9,4,5);}}); }
  }

  /* ---------- HEAD (small, menacing helmet) ----------
     Powered down, the head drops and pitches forward. Offline claude was
     previously the working model with the lights switched off and every joint
     still holding a parade stance, which is the one thing a dead machine does
     not do — and on the god-view grid "dark" alone is not a shape, it is just
     a dimmer version of the same shape. */
  var hy=150+breath+(offl?13:0), hcx=cx+(offl?5:0);
  // neck
  plate(g,[[hcx-9,206+breath],[hcx+9,206+breath],[hcx+7,196+breath],[hcx-7,196+breath]],sM,sB,null);
  /* Helmet: faceted, not domed. The old head was a soft octagon with a flat
     brow tab — a diving helmet. The crown now breaks into facets meeting at a
     ridge, the brow is a chevron dropping toward the visor centre so the
     thing scowls, and the cheeks get their own bolted guard plates below —
     three separate pieces of armour where there was one balloon. */
  plate(g,[[hcx-24,hy+34],[hcx-26,hy+10],[hcx-16,hy-4],[hcx-6,hy-9],[hcx+6,hy-9],[hcx+16,hy-4],[hcx+26,hy+10],[hcx+24,hy+34],[hcx+12,hy+48],[hcx-12,hy+48]],sT,sM,ed);
  // crown facet seams
  pl(g,hcx-6,hy-9,hcx-10,hy+2,rc,1);pl(g,hcx+6,hy-9,hcx+10,hy+2,rc,1);
  // chevron brow, centre point hanging over the visor
  plate(g,[[hcx-17,hy+6],[hcx,hy+11],[hcx+17,hy+6],[hcx+13,hy-9],[hcx-13,hy-9]],"#2e3a4c","#1a2331",ed);
  pl(g,hcx,hy-9,hcx,hy+11,rc,1);
  // side vents / breather
  [[-1],[1]].forEach(function(k){var s=k[0];RB.fillStyle=rc;for(var v=0;v<3;v++)RB.fillRect(hcx+s*16-(s<0?4:0),hy+16+v*6,4,3);});
  /* Visor. It was a flat two-stop gradient across a slit, which at this size
     reads as an orange sticker — the head is ~50px tall in the room view and
     under 20 in a grid cell, so it gets exactly one shape to make an
     impression with. What it needed was depth: a brow casting into the recess,
     a hot core that falls off to the sides rather than sliding left-to-right,
     and a lens highlight to say there is glass in front of it. */
  RB.fillStyle="#03060d";poly(RB,[[hcx-20,hy+14],[hcx+20,hy+14],[hcx+18,hy+26],[hcx-18,hy+26]]);RB.fill();
  // brow shadow into the socket — the cheapest depth cue on the whole model
  var bs=RB.createLinearGradient(0,hy+12,0,hy+22);bs.addColorStop(0,"rgba(0,0,0,0.75)");bs.addColorStop(1,"rgba(0,0,0,0)");
  RB.fillStyle=bs;poly(RB,[[hcx-20,hy+13],[hcx+20,hy+13],[hcx+19,hy+22],[hcx-19,hy+22]]);RB.fill();
  [RB,RE].forEach(function(c){ if(offl){
      /* Not a flat grey bar. A visor that has just lost power holds a last
         ember at one end — it reads as "died" rather than "was drawn dark",
         and it is the only warm pixel left on the unit, so the eye finds it. */
      c.fillStyle="#20262e";c.fillRect(hcx-16,hy+18,32,3);
      var em=c.createLinearGradient(hcx-16,0,hcx+16,0);
      em.addColorStop(0,"rgba(120,44,18,0.5)");em.addColorStop(0.42,"rgba(60,24,12,0.2)");em.addColorStop(1,"rgba(30,14,10,0)");
      c.fillStyle=em;c.fillRect(hcx-16,hy+18,32,3);return;}
    // hot at the middle, cooling toward both corners
    var vg=c.createLinearGradient(hcx-18,0,hcx+18,0);
    vg.addColorStop(0,rgba(190,70,20,0.75*corePulse));
    vg.addColorStop(0.34,rgba(255,170,80,corePulse));
    vg.addColorStop(0.5,rgba(255,226,180,corePulse));
    vg.addColorStop(0.66,rgba(255,150,60,corePulse));
    vg.addColorStop(1,rgba(190,70,20,0.75*corePulse));
    c.fillStyle=vg;poly(c,[[hcx-17,hy+16],[hcx+17,hy+16],[hcx+15,hy+24],[hcx-15,hy+24]]);c.fill();
    c.fillStyle=rgba(255,244,222,corePulse);c.fillRect(hcx-6,hy+18,12,2); });
  /* Standby sweep. Idle claude was the working model with the effects turned
     off — identical pixels, so on the grid "waiting for work" and "doing work"
     were the same picture. A slow bright cell tracking across the visor is the
     unit saying it is powered and scanning, and it only runs when idle, so the
     two states can never be confused again. */
  if(!offl&&!work){var sw3=hcx-15+((t*11)%30);
    [RB,RE].forEach(function(c){c.fillStyle=rgba(255,236,206,0.5);c.fillRect(sw3,hy+18,4,2);});}
  // glass: a specular streak across the top of the slit, not part of the emission
  RB.fillStyle="rgba(255,236,214,"+(offl?0.05:0.3)+")";poly(RB,[[hcx-15,hy+16],[hcx+4,hy+16],[hcx+1,hy+18.5],[hcx-15,hy+18.5]]);RB.fill();
  // dome specular, keyed to the lamp above and left
  if(!offl){RB.strokeStyle="rgba(150,178,214,0.22)";RB.lineWidth=2.4;RB.beginPath();RB.moveTo(hcx-19,hy+8);RB.quadraticCurveTo(hcx-13,hy-5,hcx-1,hy-6);RB.stroke();}
  // jaw grille, so the lower half of the helmet is not a blank plate
  RB.fillStyle=rc;for(var jw=0;jw<3;jw++)RB.fillRect(hcx-9+jw*7,hy+30,5,9);
  RB.fillStyle="rgba(90,110,140,0.3)";RB.fillRect(hcx-11,hy+28,24,1.5);
  // bolted cheek guards, one separate blade of armour per side
  [-1,1].forEach(function(sc2){
    plate(g,[[hcx+sc2*27,hy+10],[hcx+sc2*24,hy+40],[hcx+sc2*10,hy+46],[hcx+sc2*16,hy+26]],sM,sB,ed);
    rivet(g,hcx+sc2*21,hy+18,eH);});
  /* The head is MOUNTED. Nothing connected helmet to torso but proximity —
     the one join on the unit a viewer looks straight at. Two intake cables
     clamp under the cheek guards and run into the collar; they take their
     endpoints from hcx/hy, so when the offline head drops and pitches, the
     cables go slack with it for free. */
  [-1,1].forEach(function(sc3){
    var ax=hcx+sc3*15, ay=hy+43, bx5=cx+sc3*24, by5=222+breath, mx=hcx+sc3*27, my=(ay+by5)/2+7;
    g.strokeStyle="#05080e";g.lineWidth=3.2;g.beginPath();
    g.moveTo(ax,ay);g.quadraticCurveTo(mx,my,bx5,by5);g.stroke();
    g.strokeStyle=offl?"#2c333d":"#4d5d75";g.lineWidth=1;g.beginPath();
    g.moveTo(ax,ay);g.quadraticCurveTo(mx,my,bx5,by5);g.stroke();
    rivet(g,ax,ay,eH);});
  /* Antenna beacon. It was a constant red dot — an aircraft warning light that
     never blinks, which is the one thing they all do. Now it strobes on a
     double-flash and throws a short halo, so the highest point on the unit has
     the only hard rhythm in the frame. */
  // the mast gets a mounting: bracket plate, bolt, and a casing behind the wire
  plate(g,[[hcx+13,hy-2],[hcx+22,hy-7],[hcx+21,hy+3],[hcx+13,hy+5]],sM,sB,ed);
  rivet(g,hcx+17,hy-1,eH);
  pl(g,hcx+18,hy-4,hcx+24,hy-18,"#0a0f18",2.8);
  pl(g,hcx+18,hy-4,hcx+24,hy-18,eH,1.6);
  if(!offl){var bt=(t*0.9)%1, bl=(bt<0.08||(bt>0.16&&bt<0.24))?1:0.12;
    [RB,RE].forEach(function(c){
      var bg2=c.createRadialGradient(hcx+24,hy-18,0.5,hcx+24,hy-18,11);
      bg2.addColorStop(0,"rgba(255,110,96,"+(0.7*bl)+")");bg2.addColorStop(1,"rgba(255,80,70,0)");
      c.fillStyle=bg2;c.beginPath();c.arc(hcx+24,hy-18,11,0,7);c.fill();
      c.fillStyle="rgba(255,"+(80+120*bl)+",70,"+(0.35+0.6*bl)+")";c.beginPath();c.arc(hcx+24,hy-18,2,0,7);c.fill();});}

  /* What the chest is standing in front of. The chest plate overhangs the
     abdomen, the pelvis overhangs the thighs and the collar overhangs the
     sternum housing loop 11 added — three joins that were open seams. */
  /* Hips and knee pivots. Every limb on this unit met its body at a straight
     edge — the arms come off a pauldron, the legs come out of a tasset, and
     nothing anywhere said which way any of it is allowed to move. A ball in a
     socket is the whole vocabulary: one dark sphere, one lit crescent on the
     lamp side, one bolt at the knee. It costs four shapes per joint and it is
     the difference between a figure and a mechanism. */
  /* Speculars. modelLight is diffuse — it says how much light a surface
     receives and nothing about how sharply it gives it back, so every plate on
     every unit has had the reflectivity of matte paint. A specular is the
     small hard hit where a curved surface aims the lamp straight at you, and
     it is the last thing separating painted metal from metal. Two per unit,
     on the surfaces that are actually facing up: the pauldron crowns. */
  [-1,1].forEach(function(sg8){var px4=cx+sg8*66;
    g.save();g.globalAlpha=offl?0.14:0.55;
    var spg=g.createLinearGradient(0,222+breath,0,240+breath);
    spg.addColorStop(0,"rgba(226,238,255,0.75)");spg.addColorStop(1,"rgba(226,238,255,0)");
    g.fillStyle=spg;
    poly(g,[[px4-sg8*30,224+breath],[px4+sg8*2,220+breath],[px4+sg8*4,229+breath],[px4-sg8*28,233+breath]]);g.fill();
    g.restore();});
  [-1,1].forEach(function(sg5){
    var hx2=cx+sg5*31, hy3=357+breath*0.85;
    g.fillStyle="#04070d";g.beginPath();g.arc(hx2,hy3,11,0,7);g.fill();
    g.strokeStyle=ed;g.lineWidth=1.6;g.beginPath();g.arc(hx2,hy3,11,0,7);g.stroke();
    var hb=g.createRadialGradient(hx2-3,hy3-4,1,hx2,hy3,11);
    hb.addColorStop(0,"rgba(148,172,206,"+(offl?0.20:0.46)+")");
    hb.addColorStop(0.55,"rgba(56,68,88,0.5)");hb.addColorStop(1,"rgba(4,7,13,0.7)");
    g.fillStyle=hb;g.beginPath();g.arc(hx2,hy3,8.4,0,7);g.fill();
    var kx3=cx+sg5*30;
    g.fillStyle="#05080e";g.beginPath();g.arc(kx3+sg5*17,449,6,0,7);g.fill();
    g.fillStyle="rgba(150,174,208,"+(offl?0.12:0.30)+")";g.beginPath();g.arc(kx3+sg5*17-1,447.6,3,0,7);g.fill();
    rivet(g,kx3+sg5*17,449,eH);});
  cavity(g,cx-31,297+breath,62,34,0.28);
  cavity(g,cx-40,375+breath*0.8,80,28,0.34);
  cavity(g,cx-25,225+breath,50,17,0.30);
  buildRim(offl?[92,86,80]:[255,170,90]);       // claude: its own orange on the key side
  // two boots, flat on the deck — see FEET in drawRobot
  return {hand:handR||{x:cx,y:400},coreY:262+breath,hy:hy,offl:offl,work:work,
          feet:[{x:cx-32,y:560,w:30},{x:cx+28,y:560,w:30}]};
}

/* ===================== CODEX — heavy armored 8-legged spider (teal) ===================== */
function buildCodex(t,st){
  var offl=st==="offline", work=st==="working";
  var CX=[RB,RE,RR];for(var q=0;q<3;q++){var c0=CX[q];c0.setTransform(1,0,0,1,0,0);c0.clearRect(0,0,c0.canvas.width,c0.canvas.height);c0.setTransform(SS,0,0,SS,0,0);c0.globalAlpha=1;c0.globalCompositeOperation="source-over";c0.filter="none";}
  var cx=260, g=RB;
  var sT="#242e3d",sM="#131a25",sB="#080c13",ed="#2c3648",eH="#41506a",rc="#05080d";
  if(offl){sT="#181d25";sM="#0e131b";sB="#05080d";ed="#222932";eH="#2a323d";}
  var TEAL=offl?[70,80,92]:[55,212,166], TEALH=offl?[110,120,132]:[150,240,214];
  function te(a){return "rgba("+TEAL[0]+","+TEAL[1]+","+TEAL[2]+","+a+")";}
  function teh(a){return "rgba("+TEALH[0]+","+TEALH[1]+","+TEALH[2]+","+a+")";}
  var pulse=offl?0:(work?(0.6+0.28*Math.sin(t*6)):(0.34+0.16*Math.sin(t*2)));
  var bob=(offl||reduced)?0:Math.round(Math.sin(t*1.5)*1.4);
  /* L11 — the body rides higher in the arch. 356 was set when the deck
     station was a 46px plank; against a waist-height worktop the ball sat
     with the desk edge at its chin, a spider peering over a counter it could
     barely reach. The feet do not move — footY is absolute — so the same six
     prints hold the floor and the femurs simply stand steeper, which is what
     a spider that means to USE the bench does with its legs. */
  var slump=offl?18:0, BY=332+bob+slump;
  function limbSeg(c,x0,y0,x1,y1,w0,w1,top,bot){var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;plate(c,[[x0+nx*w0,y0+ny*w0],[x1+nx*w1,y1+ny*w1],[x1-nx*w1,y1-ny*w1],[x0-nx*w0,y0-ny*w0]],top,bot,ed);}
  function joint(c,x,y,r){c.fillStyle=sT;c.beginPath();c.arc(x,y,r,0,7);c.fill();c.fillStyle=eH;c.beginPath();c.arc(x-1,y-1,1.2,0,7);c.fill();}
  /* A plate bolted along a limb's upper edge — the armour rides the segment,
     it is not the segment. f0..f1 are fractions of the limb's length; the
     plate is chamfered at both ends so it reads as fitted, not painted. */
  function limbArmor(c,x0,y0,x1,y1,f0,f1,off,w){var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;if(ny>0){nx=-nx;ny=-ny;}
    var ax0=x0+dx*f0,ay0=y0+dy*f0,ax1=x0+dx*f1,ay1=y0+dy*f1,ch=Math.min(5,ln*(f1-f0)*0.18);
    plate(c,[[ax0+dx/ln*ch+nx*(off+w),ay0+dy/ln*ch+ny*(off+w)],[ax1-dx/ln*ch+nx*(off+w),ay1-dy/ln*ch+ny*(off+w)],[ax1+nx*off,ay1+ny*off],[ax0+nx*off,ay0+ny*off]],sT,sM,ed);
    rivet(c,(ax0+ax1)/2+nx*(off+w*0.55),(ay0+ay1)/2+ny*(off+w*0.55),eH);}
  /* Hydraulic ram: dark sleeve from the anchor, bright rod the rest of the
     way. The rod is the one polished part a working machine keeps. */
  function ram(c,x0,y0,x1,y1,sw){var mx2=x0+(x1-x0)*0.55,my2=y0+(y1-y0)*0.55;
    pl(c,x0,y0,mx2,my2,"#0a0f18",sw);pl(c,x0,y0,mx2,my2,ed,1);
    pl(c,mx2,my2,x1,y1,offl?"#333c48":"#8ea4c0",sw*0.45);
    joint(c,x0,y0,sw*0.5+1);}

  // ---- 8 legs (behind body) ----
  /* Stance. A spider that is hunting braces wide; a spider that is waiting
     draws its legs in and settles. Idle codex used to hold the full hunting
     stance with the effects switched off, so the two states were the same
     picture — now the footprint narrows by a fifth and the knees ride lower,
     which also pulls the six contact shadows in with it for free. */
  var rest=(!work&&!offl)?1:0;
  /* Loop 20 — the assembly admits where the legs live. All six legs used to
     sprout from one hidden column behind the shell — the body was a lid
     SITTING on a leg rack, which is why the two never read as one machine.
     Now the pairs are mounted where a machine would mount them: the FRONT
     pair hangs off ball mounts bolted to the lower flanks IN FRONT of the
     hull — joint, coil spring and feed cable all on show — the SIDE pair
     sockets through a gimbal ring fixed at the hull's edge, and only the
     BACK pair keeps its joints out of sight behind the shell. */
  var rootX=[60,74,24], rootY=[-14,-28,16], footY=[550,558,552];
  var footX=[150,106,60].map(function(v){return Math.round(v*(rest?0.79:1));});
  var kneeH=[74,92,78].map(function(v){return v*(rest?0.72:1);});
  function drawLeg(sgn,i,front){
    var rx=cx+sgn*rootX[i], ry=BY+rootY[i], fx=cx+sgn*footX[i], fy=footY[i];
    var k1h=Math.max(12,kneeH[i]-slump*1.3);
    var k1x=cx+sgn*(footX[i]*0.64+16), k1y=BY-k1h;                    // knee: high → steep femur
    var k2x=cx+sgn*(footX[i]+27), k2y=BY+(fy-BY)*(0.56+(offl?0.16:0)); // ankle: low + well beyond foot → sharp flex
    /* Coxa socket. The knee and the ankle have had proper joints since loop
       2 and the place each leg meets the BODY was a 5.5px dot — so eight legs
       appeared to emerge from the hull rather than to be mounted on it. An
       armoured collar with a lit rim, and the hull side of the joint darker
       than the leg side, which is what says one goes inside the other. */
    if(i===2){
    g.fillStyle="#04080c";g.beginPath();g.arc(rx,ry,10.5,0,7);g.fill();
    g.strokeStyle=ed;g.lineWidth=1.4;g.beginPath();g.arc(rx,ry,10.5,0,7);g.stroke();
    var cxg=g.createRadialGradient(rx-sgn*3,ry-3,1,rx,ry,9);
    cxg.addColorStop(0,"rgba(150,182,196,"+(offl?0.16:0.38)+")");
    cxg.addColorStop(0.6,"rgba(48,62,72,0.45)");cxg.addColorStop(1,"rgba(3,7,11,0.75)");
    g.fillStyle=cxg;g.beginPath();g.arc(rx,ry,7.8,0,7);g.fill();
    g.fillStyle=sM;g.beginPath();g.arc(rx+sgn*3.6,ry,5.4,0,7);g.fill();  // coxa stub
    }
    /* Loop 14 — the legs put on mass (operator: "they look like straws").
       Loop 1 armoured the wire; this loop admits the wire itself was the
       problem. Every segment's wall thickness goes up by half again — a limb
       that carries a war hull is a forging, not tubing — the joints and the
       claws scale with it, and the ankle overshoot pulls in 3px so the WIDER
       tarsus still flexes inside the same measured envelope. */
    limbSeg(g,rx,ry,k1x,k1y,11,8,sM,sB);      // femur: up + out
    limbSeg(g,k1x,k1y,k2x,k2y,8,5.8,sT,sB);   // tibia: down + out past the foot
    limbSeg(g,k2x,k2y,fx,fy,6,3.2,sM,sB);     // tarsus: down + in to the foot (the flex)
    /* Loop 1 — the leg is an assembly, not a wire. Six identical bare rods
       under the heaviest shell in the fleet is the claim that nothing moves
       them. Each femur now carries a chamfered armour plate bolted along its
       upper edge, with a hydraulic ram slung underneath from the coxa to
       mid-femur — sleeve at the hull end, polished rod at the load end — and
       the tibia gets a shorter guard of the same cut. All of it hangs INSIDE
       the leg's own line, so the stance (and the envelope it binds) holds. */
    /* (Refined in-loop: the first ram ran coxa → mid-femur and vanished
       behind the dome — the abdomen overhangs everything inboard of its own
       edge. A knee ram, femur underside to upper tibia, lives in the span
       the room can actually see, and it is the joint that works hardest.) */
    if(front){
      // bolted mount plate on the flank, the ball in it, and the suspension on show
      plate(g,[[rx-10,ry-7],[rx+8,ry-9],[rx+10,ry+7],[rx-8,ry+9]],sT,sM,ed);
      rivet(g,rx-6,ry-4,eH);rivet(g,rx+5,ry+5,eH);
      g.fillStyle="#04080c";g.beginPath();g.arc(rx,ry,7,0,7);g.fill();
      g.strokeStyle=ed;g.lineWidth=1.3;g.beginPath();g.arc(rx,ry,7,0,7);g.stroke();
      g.strokeStyle=offl?"#2c3440":"#5b6c85";g.lineWidth=1.2;
      g.beginPath();g.arc(rx-sgn*2,ry-2,4.4,Math.PI*0.9,Math.PI*1.6);g.stroke();
      // coil spring root → femur: the spring a walker's front mount needs
      (function(){var sx1=rx+(k1x-rx)*0.42,sy1=ry+(k1y-ry)*0.42+7,
        dx=sx1-rx,dy=sy1-(ry+6),ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;
        [["#0a0f18",3],[offl?"#39424f":"#8ea4c0",1.1]].forEach(function(st){
          g.strokeStyle=st[0];g.lineWidth=st[1];g.beginPath();g.moveTo(rx,ry+6);
          for(var q2=1;q2<7;q2++){var u4=q2/7,s4=(q2%2?1:-1);
            g.lineTo(rx+dx*u4+nx*3.4*s4,ry+6+dy*u4+ny*3.4*s4);}
          g.lineTo(sx1,sy1);g.stroke();});})();
      // slack feed cable off the hull into the femur
      var cby=ry+20+(offl?5:0);
      [["#05080e",2.6],[offl?"#2c3440":"#5b6c85",1]].forEach(function(st){
        g.strokeStyle=st[0];g.lineWidth=st[1];g.beginPath();
        g.moveTo(rx-sgn*8,ry+8);g.quadraticCurveTo(rx-sgn*2,cby,rx+(k1x-rx)*0.6,ry+(k1y-ry)*0.6+10);g.stroke();});
    }
    ram(g,rx+(k1x-rx)*0.5,ry+(k1y-ry)*0.5+10,k1x+(k2x-k1x)*0.34,k1y+(k2y-k1y)*0.34+4,5);
    limbArmor(g,rx,ry,k1x,k1y,0.18,0.92,2,6);
    limbArmor(g,k1x,k1y,k2x,k2y,0.12,0.6,1.4,4.8);
    /* Loop 21 — what the sentinel comparison actually taught. Matrix
       sentinels read as one organism because their limbs are RIBBED — dozens
       of small identical segments — and their shells are LAYERED petals
       around a lens cluster. Codex keeps its arthropod stance, but below the
       knee each leg now runs in banded segments (tibia five, tarsus four),
       which is what lets a straight drawn limb read as something that could
       curl. */
    (function(){function segBands(x0,y0,x1,y1,n,w){
      var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;
      for(var b3=1;b3<n;b3++){var u7=b3/n,bx3=x0+dx*u7,by3=y0+dy*u7;
        g.strokeStyle="rgba(3,7,12,0.55)";g.lineWidth=1.6;
        g.beginPath();g.moveTo(bx3+nx*w,by3+ny*w);g.lineTo(bx3-nx*w,by3-ny*w);g.stroke();
        g.strokeStyle="rgba(150,175,205,"+(offl?0.08:0.16)+")";g.lineWidth=0.9;
        g.beginPath();g.moveTo(bx3+nx*w+dx/ln*1.4,by3+ny*w+dy/ln*1.4);
        g.lineTo(bx3-nx*w+dx/ln*1.4,by3-ny*w+dy/ln*1.4);g.stroke();}}
      segBands(k1x,k1y,k2x,k2y,5,6.6);segBands(k2x,k2y,fx,fy,4,4.4);})();
    joint(g,k1x,k1y,7.5); joint(g,k2x,k2y,6);
    /* The knee is capped, not dotted: a fitted shield over the joint, bolted
       once, angled with the femur so each pair reads as machinery in phase. */
    var kn=Math.atan2(k1y-ry,k1x-rx);
    g.save();g.translate(k1x,k1y);g.rotate(kn);
    plate(g,[[-10,-9.5],[7,-9.5],[11,0],[7,8],[-10,8]],sT,sM,ed);g.restore();
    rivet(g,k1x-1,k1y-1,eH);
    /* Loop 10 — paint gone from the lips that lead. Constants, not noise: a
       nick is a place, and it stays where it happened. The outer legs work
       hardest, so they carry the most. */
    if(i===0){g.strokeStyle="rgba(190,208,232,"+(offl?0.12:0.3)+")";g.lineWidth=1.4;
      var u2=0.55+(sgn>0?0.09:0),px3=rx+(k1x-rx)*u2,py3=ry+(k1y-ry)*u2;
      g.beginPath();g.moveTo(px3-1,py3-6);g.lineTo(px3+1.4,py3-3.8);g.stroke();}
    // ankle clamp band where the tarsus takes the flex
    (function(){var dx=fx-k2x,dy=fy-k2y,ln=Math.hypot(dx,dy)||1,bx=k2x+dx*0.18,by2=k2y+dy*0.18,nx=-dy/ln,ny=dx/ln;
      pl(g,bx+nx*7,by2+ny*7,bx-nx*7,by2-ny*7,"#0a0f18",4);
      pl(g,bx+nx*7,by2+ny*7,bx-nx*7,by2-ny*7,eH,1.2);})();
    /* Claws. Each leg ended in a small triangle — a point, with nothing that
       explains how six of these hold a heavy shell steady. Two hooked tips
       splayed against the direction of load is what an insect foot actually
       does, and it gives the contact shadows something to be cast BY. */
    g.fillStyle=sB;g.beginPath();g.moveTo(fx-4.5,fy-4);g.lineTo(fx+4.5,fy-4);g.lineTo(fx+sgn*2.5,fy+4.8);g.closePath();g.fill();
    g.strokeStyle=sT;g.lineWidth=2.4;g.lineCap="round";
    g.beginPath();g.moveTo(fx,fy);g.quadraticCurveTo(fx-sgn*5,fy+4,fx-sgn*8,fy+1);g.stroke();
    g.beginPath();g.moveTo(fx,fy);g.quadraticCurveTo(fx+sgn*5,fy+5,fx+sgn*9,fy+2);g.stroke();
    g.lineCap="butt";
    if(!offl){RB.fillStyle=te(0.85);RB.fillRect(fx-1,fy-4,2,2);RE.fillStyle=te(0.9);RE.fillRect(fx-1,fy-4,2,2);}
  }
  for(var i=1;i<3;i++){drawLeg(-1,i);drawLeg(1,i);}
  /* Loop 22 — the light pass. New structure earns new shadow: each front
     femur lays its own soft shadow on the hull it stands in front of
     (clipped to the hull, so it never darkens the room), and after the legs
     are down the reactor tops up its spill so the mounts and springs
     standing in front of the fire actually catch some of it. */
  var drawFrontLegs=function(){
    [-1,1].forEach(function(sg){
      var rx=cx+sg*60,ry=BY-14,k1x=cx+sg*(footX[0]*0.64+16),k1y=BY-Math.max(12,kneeH[0]-slump*1.3);
      g.save();hullPath(g);g.clip();
      g.strokeStyle="rgba(0,0,0,0.30)";g.lineWidth=13;g.lineCap="round";
      g.beginPath();g.moveTo(rx+5,ry+9);g.lineTo(k1x+5,k1y+9);g.stroke();
      g.lineCap="butt";g.restore();});
    drawLeg(-1,0,true);drawLeg(1,0,true);
    if(!offl){RB.save();RB.globalCompositeOperation="lighter";
      var fsp=RB.createRadialGradient(cx,coreY,4,cx,coreY,52);
      fsp.addColorStop(0,te(0.10*pulse));fsp.addColorStop(1,te(0));
      RB.fillStyle=fsp;RB.beginPath();RB.arc(cx,coreY,52,0,7);RB.fill();RB.restore();}};
  // the side pair's gimbal rings sit at the hull's edge, drawn after it
  var drawSideGimbals=function(){[-1,1].forEach(function(sg){
    var gx1=cx+sg*84, gy1=BY-24;
    g.fillStyle="#04080c";g.beginPath();g.arc(gx1,gy1,6.5,0,7);g.fill();
    g.strokeStyle=ed;g.lineWidth=1.6;g.beginPath();g.arc(gx1,gy1,6.5,0,7);g.stroke();
    g.strokeStyle=offl?"#2c3440":"#5b6c85";g.lineWidth=1.2;
    g.beginPath();g.arc(gx1-sg*2,gy1-2,4,Math.PI*0.9,Math.PI*1.6);g.stroke();
    rivet(g,gx1-sg*5,gy1+4,eH);});};

  // ---- abdomen (faceted war hull) ----
  /* Loop 15 — the shell stops being a balloon (operator: "almost a sphere…
     I want R-rated"). An ellipse is a friendly shape no amount of grime can
     threaten with. The silhouette is now cut from facets: a peaked crown, a
     hard shoulder line each side, flared cowls standing off over the leg
     roots, a jaw that tapers instead of rounding under. Wider and lower than
     the old dome — the width lives well inside the legs' span, the crown
     stays under the vent mouths, so the envelope holds. Every clip that used
     to be the ellipse is re-cut to the hull, the nested chevrons and the
     soft top-left sheen are DELETED (a soft highlight is a friendly
     highlight), and the facet planes carry the value steps instead. */
  var ax=cx, ay=BY-44, aw=86, ah=54;
  var HP=[[0,-1],[0.28,-0.94],[0.72,-0.62],[1.0,-0.10],[0.98,0.30],[0.62,0.86],[0,1]];
  function hullPath(c){c.beginPath();c.moveTo(ax,ay-ah);
    for(var hi=1;hi<HP.length;hi++)c.lineTo(ax+HP[hi][0]*aw,ay+HP[hi][1]*ah);
    for(var hj=HP.length-2;hj>=0;hj--)c.lineTo(ax-HP[hj][0]*aw,ay+HP[hj][1]*ah);
    c.closePath();}
  /* Loop 7 — the shell casts on what it covers. The dome is the biggest
     overhang in the fleet and the legs passed behind it at full brightness,
     which is the tell that they are drawn, not under it. A contact shadow
     falls on everything within a few pixels of the shell's edge — painted
     source-atop, so it lands on the legs and never haloes the room. */
  g.save();g.globalCompositeOperation="source-atop";
  [[8,0.30],[4,0.22]].forEach(function(sh){
    g.save();g.translate(ax,ay);g.scale((aw+sh[0])/aw,(ah+sh[0])/ah);g.translate(-ax,-ay);
    g.fillStyle="rgba(0,0,0,"+sh[1]+")";hullPath(g);g.fill();g.restore();});
  g.restore();
  var abg=g.createLinearGradient(0,ay-ah,0,ay+ah);abg.addColorStop(0,sT);abg.addColorStop(1,sB);
  g.fillStyle=abg;hullPath(g);g.fill();
  // facet planes: hard value steps, keyed to the lamp upper-left
  function facet(pts,style){g.fillStyle=style;poly(g,pts.map(function(q){return [ax+q[0]*aw,ay+q[1]*ah];}));g.fill();}
  facet([[0,-1],[-0.28,-0.94],[-0.40,-0.30],[0,-0.42]],"rgba(190,215,240,"+(offl?0.05:0.10)+")");
  facet([[0,-1],[0.28,-0.94],[0.40,-0.30],[0,-0.42]],"rgba(190,215,240,"+(offl?0.02:0.045)+")");
  facet([[-0.28,-0.94],[-0.72,-0.62],[-1.0,-0.10],[-0.40,-0.30]],"rgba(0,0,0,0.10)");
  facet([[0.28,-0.94],[0.72,-0.62],[1.0,-0.10],[0.40,-0.30]],"rgba(0,0,0,0.17)");
  facet([[-0.40,-0.30],[-1.0,-0.10],[-0.98,0.30],[-0.62,0.86]],"rgba(0,0,0,0.12)");
  facet([[0.40,-0.30],[1.0,-0.10],[0.98,0.30],[0.62,0.86]],"rgba(0,0,0,0.18)");
  // seams between the planes, and a worn bright lip on the edges facing the lamp
  g.strokeStyle=rc;g.lineWidth=1.2;g.beginPath();
  g.moveTo(ax,ay-ah);g.lineTo(ax,ay-ah*0.42);
  [-1,1].forEach(function(sg){
    g.moveTo(ax+sg*0.28*aw,ay-0.94*ah);g.lineTo(ax+sg*0.40*aw,ay-0.30*ah);
    g.moveTo(ax+sg*0.40*aw,ay-0.30*ah);g.lineTo(ax+sg*1.0*aw,ay-0.10*ah);});
  g.stroke();
  g.strokeStyle="rgba(190,208,232,"+(offl?0.10:0.26)+")";g.lineWidth=1;g.beginPath();
  g.moveTo(ax,ay-ah);g.lineTo(ax-0.28*aw,ay-0.94*ah);g.lineTo(ax-0.72*aw,ay-0.62*ah);
  g.stroke();
  /* Loop 21, on the shell: the crown is layered like theirs — two nested
     petal lines step down from the peak, each a dark cut with a lit lower
     lip, so the top of the hull reads as plates OVER plates. */
  g.save();g.beginPath();g.rect(ax-aw-2,ay-ah-6,aw*2+4,ah*0.72);g.clip();
  [0.8].forEach(function(sc2){
    g.save();g.translate(ax,ay);g.scale(sc2,sc2);g.translate(-ax,-ay);
    g.strokeStyle="rgba(3,7,12,0.62)";g.lineWidth=2.2/sc2;hullPath(g);g.stroke();g.restore();
    g.save();g.translate(ax,ay+1.7);g.scale(sc2,sc2);g.translate(-ax,-ay);
    g.strokeStyle="rgba(168,200,226,"+(offl?0.07:0.15)+")";g.lineWidth=1.2/sc2;hullPath(g);g.stroke();g.restore();});
  g.restore();
  g.strokeStyle=ed;g.lineWidth=1.4;hullPath(g);g.stroke();
  g.strokeStyle=rc;g.lineWidth=1;g.beginPath();g.moveTo(ax-aw+10,ay+2);g.lineTo(ax+aw-10,ay+2);g.stroke();
  /* Cowl blades: the flared plates over the leg roots end in a spike each —
     the shell grows the same claws the feet already have. */
  [-1,1].forEach(function(sg){
    plate(g,[[ax+sg*0.93*aw,ay-0.16*ah],[ax+sg*(aw+13),ay-0.02*ah],[ax+sg*0.95*aw,ay+0.12*ah]],sM,sB,ed);});
  /* Loop 19 — CHAD PASS THREE, half one: shoulders. The shoulder line was a
     seam with a fin on it. Now each side wears a pauldron standing proud of
     the hull edge — and they do NOT match, because a veteran's shoulders
     never do: the left is the forged original, ridged and notched; the
     right is the field replacement — squarer cut, three fat bolts, no
     chamfer — the plate a crew hangs after a fight, not before one. The
     loop-12 bite carves the replacement's edge, which is why it needed
     replacing. */
  function hq(px4,py4){return [ax+px4*aw,ay+py4*ah];}
  plate(g,[hq(-0.26,-1.06),hq(-0.78,-0.66),hq(-0.86,-0.46),hq(-0.60,-0.50),hq(-0.34,-0.80)],sT,sM,ed);
  g.strokeStyle="rgba(190,208,232,"+(offl?0.14:0.34)+")";g.lineWidth=1.3;g.beginPath();
  g.moveTo(ax-0.26*aw,ay-1.06*ah);g.lineTo(ax-0.78*aw,ay-0.66*ah);g.stroke();
  g.fillStyle="rgba(2,5,9,0.7)";poly(g,[hq(-0.55,-0.80),hq(-0.63,-0.74),hq(-0.56,-0.70)]);g.fill(); // the notch
  rivet(g,ax-0.42*aw,ay-0.82*ah,eH);rivet(g,ax-0.68*aw,ay-0.60*ah,eH);
  plate(g,[hq(0.30,-1.02),hq(0.68,-0.82),hq(0.84,-0.54),hq(0.60,-0.46),hq(0.34,-0.76)],
    offl?"#232c39":"#37455c",offl?"#11161f":"#1c2635",ed);
  [[0.44,-0.84],[0.60,-0.72],[0.68,-0.58]].forEach(function(fb3){
    g.fillStyle="#0a0f18";g.beginPath();g.arc(ax+fb3[0]*aw,ay+fb3[1]*ah,2.8,0,7);g.fill();
    g.fillStyle=eH;g.beginPath();g.arc(ax+fb3[0]*aw-0.7,ay+fb3[1]*ah-0.7,1.3,0,7);g.fill();});
  g.strokeStyle="rgba(3,7,12,0.7)";g.lineWidth=1.4;g.beginPath();
  g.moveTo(ax+0.60*aw,ay-0.46*ah);g.lineTo(ax+0.50*aw,ay-0.56*ah);g.lineTo(ax+0.42*aw,ay-0.52*ah);g.stroke();
  // loop 22: the pauldrons sit ON the crown — contact shade under their inner edges
  g.fillStyle="rgba(0,0,0,0.28)";
  poly(g,[hq(-0.34,-0.78),hq(-0.60,-0.48),hq(-0.55,-0.40),hq(-0.30,-0.70)]);g.fill();
  poly(g,[hq(0.34,-0.74),hq(0.60,-0.44),hq(0.55,-0.36),hq(0.30,-0.66)]);g.fill();
  /* Half two: ribs. Claude's best delete showed the mechanism between the
     plates; codex's hull meets its legs with nothing showing, so the lower
     flanks now breathe through three rib slats a side — dark recess, bright
     lower lip, angled with the jaw facet — the structure a shell this size
     would actually have, and the first thing on it that looks like it could
     take a hit and vent it. */
  /* (Loop 20 rebuilt these: slats → the rib CAGE. Claude's waist earned its
     read by showing bone: a dark cavity with the structure crossing it. The
     flank now opens into one recessed cavity per side with four rib hoops
     spanning it — each a curved bar, lit on its outer edge — and the cavity
     runs deeper toward the rear, so the shell reads as plated OVER a frame
     rather than solid through. */
  [-1,1].forEach(function(sg){
    g.save();g.translate(ax+sg*0.58*aw,ay+0.26*ah);g.rotate(sg*0.42);
    g.fillStyle="#02050a";poly(g,[[-16,-9],[15,-11],[18,8],[-14,10]]);g.fill();
    g.strokeStyle=rc;g.lineWidth=1.2;poly(g,[[-16,-9],[15,-11],[18,8],[-14,10]]);g.stroke();
    for(var rv=0;rv<4;rv++){var rxr=-12+rv*8.6;
      g.strokeStyle="#1c2634";g.lineWidth=3;g.beginPath();
      g.moveTo(rxr,-8.4);g.quadraticCurveTo(rxr+3.4,0,rxr,9);g.stroke();
      g.strokeStyle=offl?"#39424f":"#5f7390";g.lineWidth=1.2;g.beginPath();
      g.moveTo(rxr+1.1,-8.4);g.quadraticCurveTo(rxr+4.5,0,rxr+1.1,9);g.stroke();}
    g.fillStyle="rgba(0,0,0,0.5)";poly(g,[[-16,-9],[15,-11],[15,-6],[-16,-4]]);g.fill();
    g.restore();});
  /* Loop 25 — naked wires. A machine this repaired has looms the crew
     never bothered to re-sheath: a bundle sags out of the left rib cavity
     and re-enters the hull through a grommet; a clamped run crosses the
     right flank below the patch. Small, dark, and gravity-obedient — the
     rough-service read without another plate of clutter. */
  (function(){
    var wx0=ax-0.52*aw,wy0=ay+0.40*ah,wx1=ax-0.28*aw,wy1=ay+0.56*ah;
    [["#04070c",1.6],["#04070c",1.6]].forEach(function(_,wi){});
    [[0,"#05080e",2.4],[0,offl?"#2c3440":"#5b6c85",1],[3,"#05080e",1.8],[3,offl?"#242c36":"#46566e",0.8]].forEach(function(w2){
      g.strokeStyle=w2[1];g.lineWidth=w2[2];g.beginPath();
      g.moveTo(wx0,wy0+w2[0]);g.quadraticCurveTo((wx0+wx1)/2,wy1+7+w2[0],wx1,wy1+w2[0]-2);g.stroke();});
    [[wx0,wy0],[wx1,wy1-2]].forEach(function(gr){
      g.fillStyle="#02050a";g.beginPath();g.arc(gr[0],gr[1]+1.5,2.6,0,7);g.fill();
      g.strokeStyle=ed;g.lineWidth=1;g.beginPath();g.arc(gr[0],gr[1]+1.5,2.6,0,7);g.stroke();});
    g.strokeStyle="#05080e";g.lineWidth=2;g.beginPath();
    g.moveTo(ax+0.40*aw,ay+0.05*ah);g.quadraticCurveTo(ax+0.50*aw,ay+0.12*ah,ax+0.52*aw,ay+0.21*ah);g.stroke();
    g.strokeStyle=offl?"#2c3440":"#4c5c74";g.lineWidth=0.9;g.beginPath();
    g.moveTo(ax+0.40*aw,ay+0.05*ah);g.quadraticCurveTo(ax+0.50*aw,ay+0.12*ah,ax+0.52*aw,ay+0.21*ah);g.stroke();
    [[0.44,0.085],[0.49,0.15]].forEach(function(cl){
      pl(g,ax+cl[0]*aw-2,ay+cl[1]*ah,ax+cl[0]*aw+2,ay+cl[1]*ah,"#0a0f18",2);});
  })();
  drawSideGimbals();
  /* Brushed metal. The carapace is the single largest shape codex has and it
     was a vertical two-stop gradient — perfectly smooth, which is the one
     surface quality a machined shell does not have. Anisotropic streaks
     following the curve give it a grain, and the grain is what tells you the
     dome is metal rather than plastic or paint. */
  g.save();hullPath(g);g.clip();
  for(var br=0;br<26;br++){var byv=ay-ah+br*(ah*2/26);
    g.strokeStyle="rgba(150,175,205,"+(0.014+0.02*Math.abs(Math.sin(br*2.7)))+")";
    g.lineWidth=1;g.beginPath();g.moveTo(ax-aw,byv);g.bezierCurveTo(ax-aw*0.3,byv-3,ax+aw*0.3,byv+3,ax+aw,byv);g.stroke();}
  /* Carapace segments. The abdomen was one ellipse — grained, riveted, and
     still a single closed curve, which is why it read as an inflated shape
     rather than as armour. An arthropod's dorsal shell is tergites: plates
     that overlap back-to-front, each casting a hard line onto the one behind
     and catching light on its own leading edge. Three of them turn the same
     silhouette into something built, and cost two strokes each.
     Still inside the dome clip the grain opened above, so the plates end at
     the shell edge instead of running out into the room. */
  [-0.34,0.10].forEach(function(f){var sy=ay+ah*f;
    g.strokeStyle="rgba(3,7,12,0.62)";g.lineWidth=3;
    g.beginPath();g.moveTo(ax-aw,sy-4);g.bezierCurveTo(ax-aw*0.35,sy+7,ax+aw*0.35,sy+7,ax+aw,sy-4);g.stroke();});
  g.restore();
  g.restore();
  rivet(g,ax-aw+16,ay+6,eH);rivet(g,ax+aw-16,ay+6,eH);rivet(g,ax,ay+ah-9,eH);
  // rim nicks (loop 10): the dome's leading edge meets the world first
  g.strokeStyle="rgba(190,208,232,"+(offl?0.14:0.32)+")";g.lineWidth=1.6;
  [[-0.14,-0.96],[0.9,0.03]].forEach(function(np2){
    var nx3=ax+np2[0]*aw,ny3=ay+np2[1]*ah;
    g.beginPath();g.moveTo(nx3-1.2,ny3-1.2);g.lineTo(nx3+1.6,ny3+1.4);g.stroke();});
  /* Grime obeys gravity, not the power state: oily weep below the shell's
     rivets and the saddle bolts, in albedo, so a dead codex is exactly as
     dirty as a live one. */
  (function(){g.fillStyle="rgba(58,40,26,0.30)";
    [[ax-aw+16,ay+8,9],[ax+aw-16,ay+8,7]].forEach(function(w){
      poly(g,[[w[0]-1.1,w[1]],[w[0]+1.1,w[1]],[w[0]+0.5,w[1]+w[2]],[w[0]-0.5,w[1]+w[2]]]);g.fill();});
    pl(g,ax-19,ay-ah+8.6,ax+19,ay-ah+8.6,"rgba(0,0,0,0.32)",2); // the saddle sits ON the shell
  })();
  /* Loop 4 — the spinnerets are plumbing, not prongs. Three bare stubs with
     lit tips read as antennae; a machine's vents are welded and clamped. The
     cluster now shares one bolted saddle on the shell, each pipe cants
     outward from it, wears a clamp band, and ends in a slanted hollow mouth
     with the teal ember down the throat — the pipe is dark, the heat is
     inside it. Mouth height is unchanged: codex's envelope binds the fleet's
     unit box, so the silhouette may get denser but not taller. */
  plate(g,[[ax-23,ay-ah+8],[ax+23,ay-ah+8],[ax+19,ay-ah-1],[ax-19,ay-ah-1]],sM,sB,ed);
  rivet(g,ax-18,ay-ah+4,eH);rivet(g,ax+18,ay-ah+4,eH);
  for(var n=-1;n<=1;n++){var nx2=ax+n*13;
    g.save();g.translate(nx2,ay-ah+2);g.rotate(n*0.16);
    plate(g,[[-4.5,0],[4.5,0],[3.5,-14],[-3.5,-14]],sM,sB,ed);
    pl(g,-4,-6,4,-6,"#0a0f18",2.4);pl(g,-4,-6.8,4,-6.8,eH,0.8);   // clamp band
    g.fillStyle="#03060b";g.beginPath();g.ellipse(0,-13.4,3.4,1.9,n*0.12,0,7);g.fill();
    g.restore();
    if(!offl){var mx3=nx2-Math.sin(n*0.16)*13,my3=ay-ah+2-Math.cos(n*0.16)*13;
      RB.fillStyle=te(0.5);RB.fillRect(mx3-1.6,my3+0.4,3.2,2);RE.fillStyle=te(0.55);RE.fillRect(mx3-1.6,my3+0.4,3.2,2);}}

  // ---- reactor core (abdomen front) ----
  /* Loop 2 — the reactor is housed, not a porthole. A fire this important
     was a soft disc laid ON the shell: a thin ring, three hairlines the glow
     erased, nothing that said the hull holds it. Now the fire sits down a
     bolted blast collar — recess shadow at the top where the shell overhangs
     it — and three radial vanes stand IN FRONT of it. The vanes are cut out
     of the emissive buffer too, so the bloom leaks around the grille and
     never through it: caged light is what reads as contained power. */
  var coreY=ay+10;
  RB.fillStyle="#02050a";RB.beginPath();RB.arc(cx,coreY,21,0,7);RB.fill();
  var crs=RB.createLinearGradient(0,coreY-21,0,coreY+8);
  crs.addColorStop(0,"rgba(0,0,0,0.75)");crs.addColorStop(1,"rgba(0,0,0,0)");
  RB.fillStyle=crs;RB.beginPath();RB.arc(cx,coreY,21,0,7);RB.fill();
  RB.strokeStyle=sT;RB.lineWidth=3;RB.beginPath();RB.arc(cx,coreY,21,0,7);RB.stroke();
  RB.strokeStyle=rc;RB.lineWidth=1;RB.beginPath();RB.arc(cx,coreY,22.6,0,7);RB.stroke();
  for(var bb=0;bb<6;bb++){var ba=bb*Math.PI/3+0.52;rivet(RB,cx+Math.cos(ba)*21,coreY+Math.sin(ba)*21,eH);}
  [RB,RE].forEach(function(c){if(offl){c.fillStyle="#161b22";c.beginPath();c.arc(cx,coreY,8,0,7);c.fill();return;}var cg=c.createRadialGradient(cx,coreY,1,cx,coreY,18);cg.addColorStop(0,teh(pulse));cg.addColorStop(0.4,te(0.75*pulse));cg.addColorStop(1,te(0));c.fillStyle=cg;c.beginPath();c.arc(cx,coreY,18,0,7);c.fill();c.fillStyle=teh(pulse);c.beginPath();c.arc(cx,coreY,4.5,0,7);c.fill();});
  // the core lights the carapace above it and the head plate below — see claude
  if(!offl){RB.save();RB.globalCompositeOperation="lighter";
    var tb=RB.createRadialGradient(cx,coreY,4,cx,coreY,96);
    tb.addColorStop(0,te(0.26*pulse));tb.addColorStop(0.5,te(0.09*pulse));tb.addColorStop(1,te(0));
    RB.fillStyle=tb;RB.beginPath();RB.arc(cx,coreY,96,0,7);RB.fill();RB.restore();}
  // the grille: three vanes in front of the fire, punched out of the emissive
  [ -Math.PI/2, Math.PI/6, Math.PI*5/6 ].forEach(function(va){
    var vx=Math.cos(va),vy=Math.sin(va);
    RB.strokeStyle="#0a0f18";RB.lineWidth=3.4;RB.beginPath();
    RB.moveTo(cx+vx*4,coreY+vy*4);RB.lineTo(cx+vx*19.5,coreY+vy*19.5);RB.stroke();
    RB.strokeStyle=offl?"#242a33":"#3a4658";RB.lineWidth=1.2;RB.beginPath();
    RB.moveTo(cx+vx*4-1,coreY+vy*4-1);RB.lineTo(cx+vx*19.5-1,coreY+vy*19.5-1);RB.stroke();
    RE.save();RE.globalCompositeOperation="destination-out";RE.strokeStyle="rgba(0,0,0,1)";
    RE.lineWidth=3.4;RE.beginPath();RE.moveTo(cx+vx*4,coreY+vy*4);RE.lineTo(cx+vx*19.5,coreY+vy*19.5);RE.stroke();RE.restore();});

  // ---- cephalothorax (front hull) + eye cluster ----
  /* Loop 3 — the head is mounted, not adjacent. The face hung under the dome
     with nothing carrying it: no joint, no feed, no way on or off. Now a
     pedicel does the work — two angled mounting struts bolted from the
     shell's underside to the head's shoulders, and a sensor trunk looping
     down each side into the head. Offline the mount is honest about being a
     mount: the head sags a few pixels in it and the trunks go slack. */
  var hxx=cx, hy2=BY+22+(offl?5:0);
  /* Loop 17 — CHAD PASS ONE: the neck of a fighter. Loop 3's mount was two
     sticks and two wires — anatomically honest, visually a pencil neck. What
     reads as strength on claude is what reads as strength on anyone: no
     taper between skull and shoulders. A broad trapezius collar now slopes
     from the hull's underside onto the head's shoulders, drawn behind the
     face so only its slopes show, and each side carries two FAT ribbed power
     tubes under visible tension — the bundle a head that bites needs.
     Offline the tubes bow outward and the collar is what the head visibly
     hangs from. */
  plate(g,[[hxx-50,BY+2],[hxx+50,BY+2],[hxx+36,hy2-12],[hxx-36,hy2-12]],sM,sB,ed);
  rivet(g,hxx-42,BY+6,eH);rivet(g,hxx+42,BY+6,eH);
  [-1,1].forEach(function(sg){
    var sag=offl?9:0;
    [[26,30,7],[36,40,5.2]].forEach(function(tb){
      var x0=hxx+sg*tb[0],x1=hxx+sg*(tb[1]-(offl?2:0)),cx2=hxx+sg*(tb[1]+14+sag*0.6);
      g.strokeStyle="#05080e";g.lineWidth=tb[2];g.beginPath();
      g.moveTo(x0,BY+2);g.quadraticCurveTo(cx2,BY+14+sag,x1,hy2-6);g.stroke();
      g.strokeStyle=offl?"#252d38":"#46566e";g.lineWidth=tb[2]*0.42;g.beginPath();
      g.moveTo(x0-sg,BY+2);g.quadraticCurveTo(cx2-sg*2,BY+14+sag,x1-sg,hy2-6);g.stroke();
      if(sg<0&&tb[0]===26){g.strokeStyle=offl?"#242c36":"#46566e";g.lineWidth=0.9;g.beginPath();
        g.moveTo(x0-4,BY+3);g.quadraticCurveTo(cx2-8,BY+17+sag,x1-4,hy2-4);g.stroke();}
      // corrugation: the tube is ribbed, not smooth
      g.strokeStyle="rgba(3,7,12,0.65)";g.lineWidth=1.2;
      for(var rb2=1;rb2<5;rb2++){var u3=rb2/5,qx=(1-u3)*(1-u3)*x0+2*(1-u3)*u3*cx2+u3*u3*x1,
        qy=(1-u3)*(1-u3)*(BY+2)+2*(1-u3)*u3*(BY+14+sag)+u3*u3*(hy2-6);
        g.beginPath();g.moveTo(qx-tb[2]*0.55,qy-1);g.lineTo(qx+tb[2]*0.55,qy+1);g.stroke();}
    });});
  plate(g,[[hxx-42,hy2-24],[hxx+42,hy2-24],[hxx+34,hy2+26],[hxx-34,hy2+26]],sT,sM,ed);
  plate(g,[[hxx-40,hy2-24],[hxx+40,hy2-24],[hxx+36,hy2-14],[hxx-36,hy2-14]],"#2c3849","#1a2331",null);
  /* Loop 9 — the face is armour, not a panel. One trapezoid with a socket
     cut in it read as an instrument, and an instrument does not glare. Three
     changes make it a head that means it: a brow ridge that breaks to a V
     over the socket and casts its own shade into the recess, a bolted cheek
     guard down each side, and the chin stubs rebuilt as hinged chelicerae —
     paired cutters with a pivot rivet each, the one part of a spider's face
     you do not want a closer look at. */
  [-1,1].forEach(function(sg){
    plate(g,[[hxx+sg*42,hy2-12],[hxx+sg*30,hy2-12],[hxx+sg*27,hy2+20],[hxx+sg*37,hy2+22]],sM,sB,ed);
    rivet(g,hxx+sg*33,hy2-8,eH);rivet(g,hxx+sg*32,hy2+16,eH);});
  /* Loop 18 — CHAD PASS TWO: cheekbones. What made claude's face tough was
     zygomatic width: a hard lit plane at eye level with shadow under it.
     Codex's face was widest at the brow and fell straight to the chin —
     a child's proportions. A wedge now stands proud each side at eye level,
     top plane catching the lamp, its own shade cast onto the cheek below,
     and the jaw gets a squared step so the face ends in corners, not taper. */
  [-1,1].forEach(function(sg){
    plate(g,[[hxx+sg*39,hy2-13],[hxx+sg*51,hy2-5],[hxx+sg*45,hy2+5],[hxx+sg*33,hy2-1]],sT,sM,ed);
    g.strokeStyle="rgba(190,208,232,"+(offl?0.14:0.4)+")";g.lineWidth=1.3;
    g.beginPath();g.moveTo(hxx+sg*39,hy2-13);g.lineTo(hxx+sg*51,hy2-5);g.stroke();
    g.fillStyle="rgba(0,0,0,0.35)";
    poly(g,[[hxx+sg*45,hy2+5],[hxx+sg*33,hy2-1],[hxx+sg*31,hy2+4],[hxx+sg*42,hy2+9]]);g.fill();
    plate(g,[[hxx+sg*37,hy2+12],[hxx+sg*25,hy2+15],[hxx+sg*27,hy2+25],[hxx+sg*36,hy2+22]],sM,sB,ed);
    rivet(g,hxx+sg*32,hy2+19,eH);});
  [-1,1].forEach(function(sg){var fx2=hxx+sg*9,fdrop=offl?3:0;
    plate(g,[[fx2-sg*6,hy2+22],[fx2+sg*5,hy2+22],[fx2+sg*4,hy2+30+fdrop],[fx2,hy2+38+fdrop],[fx2-sg*4,hy2+30+fdrop]],sM,sB,ed);
    rivet(g,fx2,hy2+25,eH);
    // sentinel whiskers: a feeler cable dangling off each jaw corner
    var wdrop=offl?5:0;
    g.strokeStyle="#0a0f16";g.lineWidth=1.6;g.beginPath();
    g.moveTo(hxx+sg*22,hy2+22);g.quadraticCurveTo(hxx+sg*27,hy2+31+wdrop,hxx+sg*24,hy2+38+wdrop);g.stroke();
    g.strokeStyle=offl?"#242c36":"#3d4a5e";g.lineWidth=0.8;g.beginPath();
    g.moveTo(hxx+sg*22,hy2+22);g.quadraticCurveTo(hxx+sg*27,hy2+31+wdrop,hxx+sg*24,hy2+38+wdrop);g.stroke();});
  /* Eye cluster. Six equal dots on a flat black rectangle read as a speaker
     grille, and at grid-cell size as nothing at all — codex was identified by
     its silhouette and by the reactor glow above, never by a face. A spider
     that hunts has two dominant forward eyes and a spread of smaller ones, so
     the hierarchy is now explicit: the pair is bigger, has an iris ring and a
     dark pupil, and the four secondaries stay small and dim. */
  RB.fillStyle="#04070d";rr(RB,hxx-27,hy2-11,54,24,4);RB.fill();
  RB.strokeStyle=rc;RB.lineWidth=1.4;rr(RB,hxx-27,hy2-11,54,24,4);RB.stroke();
  // recessed socket: a top-down gradient inside the plate
  var sg2=RB.createLinearGradient(0,hy2-11,0,hy2+13);sg2.addColorStop(0,"rgba(0,0,0,0.7)");sg2.addColorStop(1,"rgba(0,0,0,0)");
  RB.fillStyle=sg2;rr(RB,hxx-27,hy2-11,54,24,4);RB.fill();
  // the brow: two plates meeting in a V, and their shade falls into the socket
  [-1,1].forEach(function(sg){
    plate(g,[[hxx+sg*31,hy2-17],[hxx+sg*2,hy2-13],[hxx+sg*2,hy2-6],[hxx+sg*28,hy2-10]],sT,sM,ed);});
  g.fillStyle="rgba(0,0,0,0.38)";
  poly(g,[[hxx-28,hy2-10],[hxx+28,hy2-10],[hxx+26,hy2-5],[hxx-26,hy2-5]]);g.fill();
  /* Loop 23 — the cluster goes cold (operator: "the eyes shouldn't have
     expression — codex is meant to look cold, scary, dangerous. the sad
     eyes break that. add more eyes, like the robots from matrix"). The
     iris, the pupil, the catchlight and the loop-16 lids are all DELETED —
     every one of them was expression machinery, and expression is exactly
     what a sentinel doesn't have. What is left is a symmetric battery of
     ten identical lenses: dark bezel, cold light, nothing looking back.
     Offline the battery dies to bezels, and only the central pair catches
     the room's beacon as two red points. */
  var lenses=[[hxx-12,hy2+1,4.2],[hxx+12,hy2+1,4.2],
    [hxx-21,hy2-5,2.6],[hxx+21,hy2-5,2.6],
    [hxx-4,hy2-6,2.2],[hxx+4,hy2-6,2.2],
    [hxx-16,hy2+9,2.0],[hxx+16,hy2+9,2.0],
    [hxx-25,hy2+5,1.6],[hxx+25,hy2+5,1.6]];
  lenses.forEach(function(e,li){
    RB.strokeStyle="#02050a";RB.lineWidth=1.4;RB.beginPath();RB.arc(e[0],e[1],e[2]+0.8,0,7);RB.stroke();
    [RB,RE].forEach(function(c){
      if(offl){c.fillStyle="#1d232b";c.beginPath();c.arc(e[0],e[1],e[2]*0.8,0,7);c.fill();
        if(li<2&&c===RB){c.fillStyle="rgba(255,70,58,0.5)";c.beginPath();c.arc(e[0]+1.2,e[1]-1,0.9,0,7);c.fill();}
        return;}
      var eg=c.createRadialGradient(e[0],e[1],0.3,e[0],e[1],e[2]*2.6);
      eg.addColorStop(0,te((li<2?0.7:0.45)*pulse));eg.addColorStop(1,te(0));
      c.fillStyle=eg;c.beginPath();c.arc(e[0],e[1],e[2]*2.6,0,7);c.fill();
      c.fillStyle=teh((li<2?0.9:0.65)+0.1*pulse);c.beginPath();c.arc(e[0],e[1],e[2],0,7);c.fill();});});
  // working: one scan bar sweeps the whole battery — the cluster tracks, the face does not move
  if(work&&!offl){var sy3=hy2-9+((t*26)%22);[RB,RE].forEach(function(c){c.fillStyle=teh(0.2);c.fillRect(hxx-26,sy3,52,1);});}
  // ---- front manipulators ----
  /* Loop 6 — the pedipalps join the same machine as the legs. Two bare
     two-segment wires hung off the head in every state: the idle pose WAS
     the offline pose, and neither had a hand, just an end. Now the arms
     speak the leg language — armoured upper segment, capped elbow, a clamp
     band at the wrist — and they end in a two-finger gripper. And they POSE:
     tucked up under the chin at rest (what a spider actually does with its
     palps), slack and hanging when the power is gone, raised with the tool
     when working. */
  var handR;
  function palp(sg,mode){
    var rx=hxx+sg*20,ry=hy2+14,ex,ey,tx2,ty;
    if(mode==="raise"){ex=hxx+sg*30;ey=hy2-4;tx2=hxx+sg*22;ty=hy2-30;}
    else if(mode==="hang"){ex=hxx+sg*29;ey=hy2+34;tx2=hxx+sg*25;ty=hy2+52;}
    else{ex=hxx+sg*33;ey=hy2+24;tx2=hxx+sg*13;ty=hy2+33;}
    limbSeg(g,rx,ry,ex,ey,4.5,3.5,sM,sB);
    limbArmor(g,rx,ry,ex,ey,0.15,0.85,0.5,3);
    limbSeg(g,ex,ey,tx2,ty,3.2,2.4,sT,sB);joint(g,ex,ey,3.4);
    // wrist clamp
    (function(){var dx=tx2-ex,dy=ty-ey,ln=Math.hypot(dx,dy)||1,bx=ex+dx*0.72,by2=ey+dy*0.72,nx=-dy/ln,ny=dx/ln;
      pl(g,bx+nx*3.4,by2+ny*3.4,bx-nx*3.4,by2-ny*3.4,"#0a0f18",2.2);
      pl(g,bx+nx*3.4,by2+ny*3.4,bx-nx*3.4,by2-ny*3.4,eH,0.8);})();
    return {x:tx2,y:ty,ex:ex,ey:ey};
  }
  function gripper(p,sg){var dx=p.x-p.ex,dy=p.y-p.ey,ln=Math.hypot(dx,dy)||1,ux=dx/ln,uy=dy/ln;
    g.strokeStyle=sT;g.lineWidth=1.8;g.lineCap="round";
    g.beginPath();g.moveTo(p.x,p.y);g.quadraticCurveTo(p.x+ux*5-uy*4,p.y+uy*5+ux*4,p.x+ux*8-uy*2,p.y+uy*8+ux*2);g.stroke();
    g.beginPath();g.moveTo(p.x,p.y);g.quadraticCurveTo(p.x+ux*5+uy*4,p.y+uy*5-ux*4,p.x+ux*8+uy*2,p.y+uy*8-ux*2);g.stroke();
    g.lineCap="butt";}
  var pL=palp(-1,offl?"hang":"tuck");gripper(pL,-1);
  if(work){var pR=palp(1,"raise");
    plate(g,[[pR.x-5,pR.y-5],[pR.x+6,pR.y-6],[pR.x+5,pR.y+5],[pR.x-6,pR.y+4]],sM,sB,ed);
    handR={x:pR.x+2,y:pR.y};}
  else{var pR2=palp(1,offl?"hang":"tuck");gripper(pR2,1);handR={x:pR2.x,y:pR2.y};}
  if(work&&handR){var h=handR;
    if(ROOM==="builder"){plate(g,[[h.x-2,h.y+2],[h.x+10,h.y-3],[h.x+14,h.y+2],[h.x+2,h.y+9]],"#2a3444","#12181f","#3d4c63");}
    else if(ROOM==="reviewer"){plate(g,[[h.x-3,h.y-9],[h.x+15,h.y-11],[h.x+15,h.y+2],[h.x-3,h.y+4]],"#1a2836","#0c1620","#3a5570");if(!offl){RB.fillStyle="rgba(130,205,255,0.75)";RB.fillRect(h.x+1,h.y-7,10,7);RE.fillStyle="rgba(130,205,255,0.7)";RE.fillRect(h.x+1,h.y-7,10,7);}}
    else{plate(g,[[h.x-2,h.y-11],[h.x+9,h.y-13],[h.x+12,h.y+4],[h.x+1,h.y+6]],"#241a30","#140e1c","#4a3a5e");if(!offl){RB.fillStyle="rgba(201,139,255,0.75)";RB.fillRect(h.x+2,h.y-9,4,5);RE.fillStyle="rgba(201,139,255,0.7)";RE.fillRect(h.x+2,h.y-9,4,5);}}
  }

  /* The dome hangs over the head plate. It is the deepest overhang on any of
     the four — the whole abdomen is in front of and above the cephalothorax —
     and the two were meeting at a clean line. */
  /* A hazard stripe on the leading tergite, and worn tips.
     codex carries a heavy shell over six legs through a workshop, and nothing
     on it said "this edge is at head height" — a marking the OTHER units would
     need. The tarsus tips take the wear, because they are what touches the
     deck: bare metal through the coating, and only at the very ends. */
  /* The dome specular. This is the largest curved surface in the fleet — it
     has had a grain since loop 6 and tergites since loop 11, and never once a
     highlight, which is why it kept reading as a matte shell no matter how
     much structure went onto it. One tight hot spot up and left, where the
     lamp is, plus the wide soft return underneath it. */
  if(!offl){g.save();g.fillStyle="rgba(228,244,255,0.075)";
    poly(g,[[ax-0.05*aw,ay-0.97*ah],[ax-0.28*aw,ay-0.90*ah],[ax-0.34*aw,ay-0.52*ah],[ax-0.08*aw,ay-0.56*ah]]);g.fill();
    var dsp=g.createRadialGradient(ax-aw*0.2,ay-ah*0.78,1,ax-aw*0.18,ay-ah*0.7,aw*0.2);
    dsp.addColorStop(0,"rgba(228,244,255,0.17)");dsp.addColorStop(1,"rgba(228,244,255,0)");
    hullPath(g);g.clip();g.fillStyle=dsp;g.fillRect(ax-aw,ay-ah,aw*2,ah*2);
    g.restore();}
  /* Loop 5 — the hazard marking follows the plate it warns about. Seven
     rotated squares hung mid-dome like confetti: paint that ignored the
     shell's own geometry. The chevron band now rides the LEADING tergite
     edge — evaluated along the same bezier the plate line is drawn with, so
     every segment sits on the curve and turns with it — and it is worn the
     way deck paint wears: thin, nicked, gone entirely at one stretch where
     something scraped it off. */
  g.save();hullPath(g);g.clip();
  (function(){var sy=ay-ah*0.34;
    var P=[[ax-aw,sy-6],[ax-aw*0.35,sy+5],[ax+aw*0.35,sy+5],[ax+aw,sy-6]];
    function bz(u){var v=1-u;return [
      v*v*v*P[0][0]+3*v*v*u*P[1][0]+3*v*u*u*P[2][0]+u*u*u*P[3][0],
      v*v*v*P[0][1]+3*v*v*u*P[1][1]+3*v*u*u*P[2][1]+u*u*u*P[3][1]];}
    g.globalAlpha=offl?0.18:0.42;
    for(var s2=0;s2<16;s2++){var u0=0.12+s2*0.048,pt=bz(u0),pt2=bz(u0+0.048);
      if(s2===9||s2===10)continue;                       // the scrape took these
      var ang=Math.atan2(pt2[1]-pt[1],pt2[0]-pt[0]);
      g.save();g.translate(pt[0],pt[1]);g.rotate(ang);
      g.fillStyle=s2%2?"#c9a227":"#141a12";
      g.beginPath();g.moveTo(0,-4.5);g.lineTo(4,-4.5);g.lineTo(7.5,4.5);g.lineTo(3.5,4.5);g.closePath();g.fill();
      g.restore();}
    // paint nicks: the band's leading edge takes the hits
    g.globalAlpha=offl?0.1:0.22;g.fillStyle="#0b0f16";
    [[0.2,-2],[0.34,1],[0.55,-1],[0.78,2]].forEach(function(k){var pt=bz(k[0]);
      g.fillRect(pt[0]-1.5,pt[1]+k[1]-1.5,3,3);});
  })();
  g.globalAlpha=1;g.restore();
  /* Loop 24 — the quiet pass (operator: "the last iteration + damage
     starts to look like a bit too much"). Nothing new: the scorch fades to
     a stain, the gouge heals to a scratch, the crack keeps its strap but
     loses its stitch ticks, half the rim nicks and half the bolt weep go,
     one tergite line and one crown petal go. Damage stays where it earns
     the veteran read; everywhere else the metal calms down so the NEW
     structure — mounts, ribs, lenses — is what the eye finds first. */
  /* Loop 8 — a service history. Every plate on the dome was the plate it
     shipped with. One repair, right flank: a scorch the shell never fully
     shed, and a patch of newer, bluer steel bolted over it — tacked with
     weld stitches along its top edge first, the way field repairs are, its
     edges aligned with nothing. Lower left, a gouge through two chevrons:
     dark trench, bright torn lip, ending where whatever made it stopped. */
  g.save();hullPath(g);g.clip();
  (function(){var px2=ax+aw*0.42,py2=ay-ah*0.02;
    var sc2=g.createRadialGradient(px2,py2,2,px2,py2,11);
    sc2.addColorStop(0,"rgba(8,6,4,0.32)");sc2.addColorStop(0.7,"rgba(12,10,7,0.16)");sc2.addColorStop(1,"rgba(12,10,7,0)");
    g.fillStyle=sc2;g.beginPath();g.arc(px2,py2,11,0,7);g.fill();
    g.save();g.translate(px2,py2);g.rotate(-0.22);
    var pg=g.createLinearGradient(0,-9,0,9);pg.addColorStop(0,"#31405a");pg.addColorStop(1,"#1c2637");
    g.fillStyle=pg;g.fillRect(-8,-9,16,18);g.strokeStyle=ed;g.lineWidth=1.2;g.strokeRect(-8,-9,16,18);
    g.strokeStyle="rgba(170,192,222,"+(offl?0.14:0.34)+")";g.lineWidth=1;
    for(var wl=0;wl<4;wl++){g.beginPath();g.moveTo(-6+wl*4,-9);g.lineTo(-4+wl*4,-11.5);g.stroke();}
    rivet(g,-5.5,-6,eH);rivet(g,5.5,-6,eH);rivet(g,-5.5,6,eH);rivet(g,5.5,6,eH);
    g.restore();
    var gx=ax-aw*0.42,gy=ay+ah*0.22;
    pl(g,gx,gy,gx+16,gy+7,"rgba(3,7,12,0.45)",2);
    pl(g,gx+0.6,gy-1,gx+16.6,gy+6,"rgba(170,192,222,"+(offl?0.08:0.2)+")",1);
    /* Loop 11 — BATTLE ONE: the strapped crack. Something split the left
       flank along a tergite once. The weld runs jagged — segment by segment,
       the way a torch chases a crack — with stitch ticks across it, and a
       strap of newer steel is bolted ACROSS the line with two fat bolts. A
       weld you strap is a weld you no longer worry about. */
    var ck=[[ax-aw*0.78,ay+ah*0.1],[ax-aw*0.62,ay+ah*0.04],[ax-aw*0.52,ay+ah*0.12],[ax-aw*0.38,ay+ah*0.05],[ax-aw*0.28,ay+ah*0.1]];
    g.strokeStyle="rgba(4,8,14,0.7)";g.lineWidth=2.2;g.beginPath();
    g.moveTo(ck[0][0],ck[0][1]);for(var ci=1;ci<ck.length;ci++)g.lineTo(ck[ci][0],ck[ci][1]);g.stroke();
    g.strokeStyle="rgba(170,192,222,"+(offl?0.14:0.3)+")";g.lineWidth=1;g.beginPath();
    g.moveTo(ck[0][0],ck[0][1]-1.2);for(var ci2=1;ci2<ck.length;ci2++)g.lineTo(ck[ci2][0],ck[ci2][1]-1.2);g.stroke();
    g.save();g.translate(ax-aw*0.52,ay+ah*0.09);g.rotate(1.35);
    var sg3=g.createLinearGradient(0,-5,0,5);sg3.addColorStop(0,"#31405a");sg3.addColorStop(1,"#1c2637");
    g.fillStyle="rgba(0,0,0,0.3)";g.fillRect(-4.5,-9.5,11,21);
    g.fillStyle=sg3;g.fillRect(-5,-10,10,20);g.strokeStyle=ed;g.lineWidth=1.1;g.strokeRect(-5,-10,10,20);
    rivet(g,0,-6,eH);rivet(g,0,6,eH);
    g.restore();
    /* Loop 13 — BATTLE THREE'S LEDGER. The other three carry stencils; a
       shell this scarred had no designation at all. A geometric stencil
       block in the fleet's worn gold — a glyph would be mush at grid-cell
       size — set on the lower flank where a crew would actually paint it,
       and beside it three tally strokes in the same paint, one per battle
       walked away from. The count matches the scars: the crack, the bite,
       the gouge. */
    g.save();g.translate(ax+aw*0.38,ay+ah*0.5);g.rotate(-0.18);
    g.globalAlpha=offl?0.25:0.5;g.fillStyle="#c9a227";
    g.fillRect(0,0,3,11);g.fillRect(5.5,0,3,11);
    g.fillStyle="rgba(201,162,39,0.6)";g.fillRect(0,13,8.5,2);
    for(var tl2=0;tl2<3;tl2++)g.fillRect(12+tl2*4,2,2,7);
    g.restore();
  })();
  g.restore();
  cavity(g,hxx-43,hy2-25,86,26,0.5);
  drawFrontLegs();
  /* Loop 12 — BATTLE TWO: the bite. Something took a piece of the dome's
     upper-right rim and kept it. Cut to transparency, not painted dark, so
     the room shows through the tear and the rim light — computed from the
     silhouette after this — breaks and catches on the torn edge. Silhouette
     damage is the one scar a repaint cannot hide. */
  g.save();g.globalCompositeOperation="destination-out";
  poly(g,[[ax+0.36*aw,ay-1.02*ah],[ax+0.62*aw,ay-0.84*ah],[ax+0.56*aw,ay-0.62*ah],[ax+0.40*aw,ay-0.66*ah]]);g.fill();g.restore();
  g.strokeStyle="rgba(190,208,232,"+(offl?0.16:0.45)+")";g.lineWidth=1.2;
  g.beginPath();g.moveTo(ax+0.36*aw,ay-1.02*ah);g.lineTo(ax+0.40*aw,ay-0.66*ah);g.lineTo(ax+0.56*aw,ay-0.62*ah);g.stroke();
  buildRim(offl?[80,90,88]:[55,212,166]);       // codex: teal
  /* Six tarsus tips, not one blob under the body: the whole point of the
     spider is the stance, and the stance is where the feet are. */
  var CFEET=[];[-1,1].forEach(function(sg){for(var fi=0;fi<3;fi++)CFEET.push({x:cx+sg*footX[fi],y:footY[fi],w:13});});
  return {hand:handR||{x:cx+18,y:BY+42},coreY:coreY,hy:hy2-10,offl:offl,work:work,feet:CFEET};
}

/* ===================== GROK — grounded stalker, cable-maned hunter (purple) ===================== */
/* The unit that used to draw here was a soft EVA balloon, and the #200 draft
   hardened it into a canopy flight suit — a unit with, either way, NO FACE:
   the one member of the fleet with nothing to be a veteran with. The concept
   that replaced it: the fleet's PREDATOR. Where claude stands, codex plants
   and kimi presses, grok HUNTS — grounded now, digitigrade, wiry, weight
   ahead of the hips; a machined mask whose built-in structure does the
   intimidating, and a mane of black armored cables slicked back over the
   crown and falling past the shoulders. The flight story survives only as
   history (reentry streaks, the GX-07 stencil): this thing came back from
   orbit once, and never needed to go up again. */
function buildGrok(t,st){
  var offl=st==="offline", work=st==="working";
  var ctxs=[RB,RE,RR];for(var i=0;i<3;i++){var c=ctxs[i];c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,c.canvas.width,c.canvas.height);c.setTransform(SS,0,0,SS,0,0);c.globalAlpha=1;c.globalCompositeOperation="source-over";c.filter="none";}
  var cx=260, g=RB;
  // same war-metal as the rest of the fleet — vendor identity lives in the
  // lights and the rim, never in the paint (the kimi round-2 lesson)
  var sT="#242e3d",sM="#131a25",sB="#080c13",ed="#2c3648",eH="#41506a",rc="#05080d";
  if(offl){sT="#181d25";sM="#0e131b";sB="#05080d";ed="#222932";eH="#2a323d";}
  var PUR=offl?[74,80,92]:[176,124,255], PURH=offl?[110,116,128]:[224,204,255];
  function pu(a){return rgba(PUR[0],PUR[1],PUR[2],a);}
  function puh(a){return rgba(PURH[0],PURH[1],PURH[2],a);}
  var pulse=offl?0:(work?(0.6+0.24*Math.sin(t*7)):(0.34+0.15*Math.sin(t*2)));
  // a stalker breathes shallow and quick — coiled, never at parade rest
  var breath=(reduced||offl)?0:Math.sin(t*1.7)*1.6;
  var sway=(reduced||offl)?0:Math.sin(t*1.3);
  /* The collapse. Dead is not "dark idle": the crouch folds deeper, the head
     drops, the mane spills FORWARD over the mask, the claws fall open. The
     feet never leave the deck — a grounded unit dies standing in its own
     stance. */
  var d=offl?22:0;
  /* THE STANCE. Ready-to-attack is a geometry, not a mood: the upper body
     drops SD into deeper knee flex (the coil — soles never move), shifts WS
     toward the lead-left foot, and the feet STAGGER — lead planted wide,
     trail tucked under the mass. Working coils deeper still. Dead keeps SD:
     the unit dies in its stance, d does the folding. The torso/head/arms all
     ride one translate; the legs are drawn in world coords to the same hip. */
  var SD=work?30:24, WS=offl?0:-6;
  function stanceOn(){[RB,RE,RR].forEach(function(c2){c2.save();c2.translate(WS,SD);});}
  function stanceOff(){[RB,RE,RR].forEach(function(c2){c2.restore();});}
  function limbSeg(c,x0,y0,x1,y1,w0,w1,top,bot){var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;plate(c,[[x0+nx*w0,y0+ny*w0],[x1+nx*w1,y1+ny*w1],[x1-nx*w1,y1-ny*w1],[x0-nx*w0,y0-ny*w0]],top,bot,ed);}
  function joint(x,y,r){g.fillStyle="#04070d";g.beginPath();g.arc(x,y,r,0,7);g.fill();
    g.strokeStyle=ed;g.lineWidth=1.4;g.beginPath();g.arc(x,y,r,0,7);g.stroke();
    var jb=g.createRadialGradient(x-r*0.3,y-r*0.35,1,x,y,r);
    jb.addColorStop(0,"rgba(148,172,206,"+(offl?0.16:0.4)+")");
    jb.addColorStop(0.6,"rgba(56,68,88,0.5)");jb.addColorStop(1,"rgba(4,7,13,0.7)");
    g.fillStyle=jb;g.beginPath();g.arc(x,y,r*0.75,0,7);g.fill();}
  // tendon: the stalker's muscle — a dark cable with a bright rod, under
  // tension wherever a limb is loaded. Same language as the fleet's
  // actuators, but strung on the OUTSIDE: this unit wears its wiring.
  function tendon(x0,y0,x1,y1,w){
    pl(g,x0,y0,x1,y1,"#0a0f18",w||3.4);
    pl(g,x0,y0,x1,y1,offl?"#333c48":"#7e94b2",1.1);}
  // ONE key, upper-left: mirrored speculars are never mirrored in intensity —
  // the left member takes the lamp, the right sits in HALF fill: any lower
  // and the dark flank sinks into the stage wall
  function kf(s){return s<0?1:0.5;}
  // an emissive needs a FIXTURE: dark housing slot first, light bar inset —
  // a bare pill on plate reads as a floating sprite
  function litBar(bx,by,w){
    g.fillStyle="#02040a";rr(g,bx-(w+1.2)/2,by-1.7,w+1.2,3.4,1);g.fill();
    g.strokeStyle=ed;g.lineWidth=0.8;rr(g,bx-(w+1.2)/2,by-1.7,w+1.2,3.4,1);g.stroke();
    [RB,RE].forEach(function(c2){c2.fillStyle=pu(offl?0.2:0.75);c2.fillRect(bx-(w-1)/2,by-0.75,w-1,1.5);});}

  // head reference — the mane and the mask both hang off this. Working the
  // head JUTS: sunk a touch deeper between the crowns, leading the mass
  var hby=166+(offl?13:0)+(work?3:0)+breath*0.5, hcx=cx+(offl?3:0);

  /* ---------- THE MANE, rear layer ----------
     The signature. Black armored cables slick back over the crown and fall
     BEHIND the shoulders — drawn first, so every plate of the body overlaps
     them and they read as coming from behind the skull. Live they hold
     tension: swept, tips riding at shoulder-blade height, one slow sway.
     Dead they just hang. Each tip carries a machined ferrule — DARK: every
     rear tip ends up behind chest or arm plate, and an emissive whose
     housing is buried reads as a sprite floating on whatever hides it. The
     mane's purple lives in the front dreads, whose ferrules show. */
  /* a dread is a CABLE: fat at the root, tapering to its ferrule, bowing
     OUT off the temple before it falls — one stiff quadratic at constant
     width reads as rope. Sampled cubic, width stepped per segment, round
     caps, highlight ride on the lit side only. */
  function cable(ax,ay,c1x,c1y,c2x,c2y,tx,ty,w0,w1,hi){
    var P=[];for(var i5=0;i5<=5;i5++){var u=i5/5,v=1-u;
      P.push([v*v*v*ax+3*v*v*u*c1x+3*v*u*u*c2x+u*u*u*tx,
              v*v*v*ay+3*v*v*u*c1y+3*v*u*u*c2y+u*u*u*ty]);}
    g.lineCap="round";
    for(var i6=0;i6<5;i6++){
      g.strokeStyle="#07090f";g.lineWidth=w0+(w1-w0)*(i6/4.5);
      g.beginPath();g.moveTo(P[i6][0],P[i6][1]);g.lineTo(P[i6+1][0],P[i6+1][1]);g.stroke();}
    if(hi){g.strokeStyle=hi;g.lineWidth=1;g.beginPath();g.moveTo(P[0][0]-1,P[0][1]-0.8);
      for(var i7=1;i7<4;i7++)g.lineTo(P[i7][0]-1,P[i7][1]-0.8);g.stroke();}
    g.lineCap="butt";return P;}
  var REARC=[[-1,13,36,268],[-1,18,48,286],[-1,23,60,300],[-1,27,68,252],
              [1,13,36,268],[1,18,48,286],[1,23,60,300],[1,27,68,252]];
  stanceOn();
  REARC.forEach(function(cb,ci){var s=cb[0], ax=hcx+s*cb[1], ay=hby+10, rank=ci%4;
    var tx=cx+s*cb[2]+(offl?s*6:0), ty=cb[3]+(offl?30:sway*2.5*(ci%2?1:-1));
    var c1x=hcx+s*(cb[1]+(offl?10:(rank>=2?30:22))), c1y=offl?hby+30:hby+18+rank*2,
        c2x=tx+s*(rank>=2?13:8), c2y=(ty+hby+60)/2+(offl?14:0);
    var w0=6.4-rank*0.55, w1=3.4-rank*0.35;
    var P=cable(ax,ay,c1x,c1y,c2x,c2y,tx,ty,w0,w1,offl?"#20242c":(s<0?"#4e5a6e":"#242b36"));
    // ferrule: the machined weight, sized to the tip's own gauge
    var fw3=w1+2.4;
    g.fillStyle="#10151d";rr(g,tx-fw3/2,ty,fw3,7-rank*0.5,1);g.fill();
    g.strokeStyle=ed;g.lineWidth=1;rr(g,tx-fw3/2,ty,fw3,7-rank*0.5,1);g.stroke();
    if(rank===1){ // ring band mid-length — the reference dreads carry metal rings
      var q=P[3];
      g.fillStyle="#232b38";g.fillRect(q[0]-3,q[1]-1.6,6,3.2);
      pl(g,q[0]-3,q[1]-1.4,q[0]+3,q[1]-1.4,"rgba(150,172,204,"+(offl?0.1:0.3)+")",0.9);}
  });
  stanceOff();

  // ---------- LEGS: digitigrade — the third segment a walker does not have ----------
  /* below the pelvis the fleet palette bottoms out INTO the stage's own
     values and the legs vanish from the waist down. The legs get their own
     plate palette, one step up the lamp — still war-metal, no wash: the
     shank must carry the read the chest carries. */
  var lT=offl?"#232b3b":"#35445e",lM=offl?"#161d2a":"#202c40",lB=offl?"#0c111b":"#121a28";
  function leg(sgn){
    /* the coil: hip rides the dropped pelvis, the knee is thrown far out and
       the shank rakes hard back in — a deep zigzag holds SD of travel the
       old straight column had to spend on length. Lead-left plants wide,
       trail-right tucks under the hips: the stagger is the attack. */
    var lead=sgn<0;
    var hx=cx+WS+sgn*20, hy0=362+SD+d*0.4+breath*0.3;
    var kx=cx+sgn*(offl?54:(lead?58:50)), ky=(lead?452:456)+d*0.3;
    var ax=cx+sgn*(lead?45:30), ay=(lead?516:518)+d*0.1;
    var fx=cx+sgn*(lead?52:38), fy=546;
    /* loop 8: the QUADS. A predator's engine is its hindquarters — the thigh
       is now the widest thing below the chest, with its own armour slab
       riding the outer face, and the shank carries a calf swell before it
       rakes to the ankle. The tendons stay strung outside the meat. */
    limbSeg(g,hx,hy0,kx,ky,20,13,lT,lM);
    plate(g,[[hx+sgn*5,hy0+2],[hx+sgn*14,hy0+8],[kx+sgn*6,ky-14],[kx-sgn*3,ky-10]],lT,lM,ed);
    /* the net: the reference wears diamond mesh under the plate — here it is
       a whisper of crosshatch on the slab face, armor texture, not fishnet */
    g.save();g.beginPath();
    [[hx+sgn*6,hy0+4],[hx+sgn*13,hy0+9],[kx+sgn*5,ky-15],[kx-sgn*2,ky-11]].forEach(function(pp,pi){pi?g.lineTo(pp[0],pp[1]):g.moveTo(pp[0],pp[1]);});
    g.closePath();g.clip();
    g.strokeStyle="rgba(3,6,12,0.35)";g.lineWidth=0.8;g.beginPath();
    for(var mh=-3;mh<9;mh++){
      g.moveTo(hx+sgn*(2+mh*4),hy0-2);g.lineTo(kx+sgn*(mh*4-8),ky);
      g.moveTo(hx+sgn*(2+mh*4),hy0-2);g.lineTo(kx+sgn*(mh*4+16),ky);}
    g.stroke();g.restore();
    pl(g,hx+sgn*6,hy0+4,kx+sgn*4,ky-13,"rgba(150,172,204,"+((offl?0.08:0.22)*kf(sgn))+")",1);
    tendon(hx-sgn*7,hy0+8,kx-sgn*5,ky-6);
    // shank — calf swell at the top, raking thin toward the high ankle
    limbSeg(g,kx,ky,ax,ay,13,7.2,lT,lM);
    // calf swell hugs the shank axis — corners inside the silhouette
    plate(g,[[kx-sgn*5,ky+7],[kx+sgn*2,ky+10],[ax+sgn*1,ay-22],[ax-sgn*4,ay-24]],lM,lB,null);
    pl(g,kx-sgn*3,ky+8,ax-sgn*2,ay-4,rc,1);
    // the shin's leading edge catches the lamp all the way down
    pl(g,kx+sgn*3,ky+8,ax+sgn*2,ay-6,"rgba(150,172,204,"+((offl?0.08:0.24)*kf(sgn))+")",1);
    // grazes: the shin is what goes through the door first
    pl(g,kx+sgn*1,ky+22,kx+sgn*6,ky+27,"rgba(190,208,232,"+(offl?0.08:0.22)+")",1);
    pl(g,ax+sgn*1,ay-16,ax+sgn*5,ay-12,"rgba(190,208,232,"+(offl?0.07:0.18)+")",0.9);
    // the key edge: only the LEFT leg's outer contour carries the full lamp
    if(sgn<0){pl(g,hx-12,hy0+6,kx-8,ky-8,"rgba(186,205,238,"+(offl?0.12:0.3)+")",1.4);
      pl(g,kx-8,ky+8,ax-4.5,ay-8,"rgba(186,205,238,"+(offl?0.14:0.34)+")",1.4);}
    // metatarsal — drops forward onto the toes
    limbSeg(g,ax,ay,fx,fy,7,9.5,lM,lB);
    joint(ax,ay,5);
    // heel spur behind the ankle
    plate(g,[[ax-sgn*2,ay+3],[ax-sgn*12,ay+10],[ax-sgn*3,ay+15]],lM,lB,null);
    // knee: joint first, pointed guard bolted over it. The guard HUGS the
    // bent joint — top edge raked back along the thigh axis, spike thrown
    // outboard-down the way the shank leaves: a guard square to the world
    // floats off a knee that isn't
    joint(kx,ky,7);
    plate(g,[[kx-sgn*11,ky-12],[kx+sgn*7,ky-11],[kx+sgn*16,ky+3],[kx+sgn*5,ky+12],[kx-sgn*8,ky+5]],
      offl?(sgn<0?"#252d3d":"#232c3c"):(sgn<0?"#3a4a66":"#364764"),lM,ed);
    rivet(g,kx+sgn*3,ky-1,eH);
    // the guards lead every contact: paint gone from the spike lips
    pl(g,kx+sgn*9,ky-9,kx+sgn*15,ky+1,"rgba(190,208,232,"+((offl?0.12:0.3)*kf(sgn))+")",1.2);
    /* clawed foot, with DEPTH: a heel block aft, an instep deck whose TOP
       face takes the lamp, and a toe bar all three claws root into — a foot
       that occupies floor, not a comb balanced on a line */
    plate(g,[[fx-sgn*10,fy-2],[fx-sgn*20,fy+1],[fx-sgn*19,fy+9],[fx-sgn*9,fy+8]],lM,lB,ed);
    plate(g,[[fx-17,fy+1],[fx+17,fy+1],[fx+18,fy+7],[fx-18,fy+7]],lT,lM,ed);
    plate(g,[[fx-12,fy-3],[fx+11,fy-3],[fx+16,fy+2],[fx-17,fy+2]],
      offl?(sgn<0?"#2b3446":"#252e40"):(sgn<0?"#46587a":"#3b4c6a"),lT,ed);
    plate(g,[[fx-18,fy+6],[fx+18,fy+6],[fx+18,fy+9.5],[fx-18,fy+9.5]],lM,lB,null);
    [-1,0,1].forEach(function(ti){var tx2=fx+ti*11;
      plate(g,[[tx2-5,fy+8],[tx2+5,fy+8],[tx2+2.6,560],[tx2-2.6,560]],lT,lB,null);
      // bare metal at the deck stays DARK — brightness at contact reads as glow
      g.fillStyle="rgba(150,168,192,"+(offl?0.06:0.12)+")";g.fillRect(tx2-2.6,557.4,5.2,2.6);});
  }
  leg(-1);leg(1);
  stanceOn();

  /* ---------- PELVIS: a girdle, not an afterthought ----------
     loop 10: the thighs got their mass in loop 8 and the pelvis they hung
     from was still the starved unit's. A real waist band bridges abdomen to
     girdle, tassets ride the hip line over the quads, and the hip balls
     grow to carry what they now carry. */
  plate(g,[[cx-21,338+d*0.62+breath*0.6],[cx+21,338+d*0.62+breath*0.6],[cx+20,348+d*0.6],[cx-20,348+d*0.6]],sT,sM,ed);
  plate(g,[[cx-31,348+d*0.6+breath*0.5],[cx+31,348+d*0.6+breath*0.5],[cx+22,380+d*0.55],[cx-22,380+d*0.55]],sT,sM,ed);
  g.fillStyle="rgba(168,192,226,"+(offl?0.06:0.16)+")";
  poly(g,[[cx-31,348+d*0.6+breath*0.5],[cx+31,348+d*0.6+breath*0.5],[cx+28,353+d*0.6],[cx-28,353+d*0.6]]);g.fill();
  // tassets: one angled plate per hip, thrown over the quad
  [-1,1].forEach(function(s){
    plate(g,[[cx+s*20,350+d*0.6],[cx+s*37,353+d*0.58],[cx+s*32,376+d*0.56],[cx+s*18,371+d*0.56]],sM,sB,ed);
    rivet(g,cx+s*25,357+d*0.58,eH);});
  /* the TROPHIES: three severed cables lashed to the left tasset, different
     gauges — none of them grok's own. The predator keeps score. */
  (function(){var ty5=372+d*0.56;
    [[-31,13,4.4],[-26,16,3.4],[-21,11,2.6]].forEach(function(tr,tri){
      var tx5=cx+tr[0];
      g.strokeStyle="#07090f";g.lineWidth=tr[2];
      g.beginPath();g.moveTo(tx5,ty5);g.quadraticCurveTo(tx5-2,ty5+tr[1]*0.6,tx5-3+tri,ty5+tr[1]);g.stroke();
      g.strokeStyle=offl?"#20242c":"#3d4756";g.lineWidth=0.9;
      g.beginPath();g.moveTo(tx5-1,ty5+1);g.quadraticCurveTo(tx5-3,ty5+tr[1]*0.6,tx5-4+tri,ty5+tr[1]-1);g.stroke();
      g.fillStyle="#10151d";g.fillRect(tx5-3+tri-tr[2]/2,ty5+tr[1]-1,tr[2]+1,3);
      pl(g,tx5-3+tri-tr[2]/2,ty5+tr[1]-0.8,tx5-3+tri+tr[2]/2+1,ty5+tr[1]-0.8,"rgba(170,192,222,"+(offl?0.1:0.26)+")",0.8);});
    // the lash that holds them
    pl(g,cx-33,ty5+0.5,cx-18,ty5+0.5,"#0a0f18",2.2);
    pl(g,cx-33,ty5-0.6,cx-18,ty5-0.6,"rgba(150,172,204,"+(offl?0.08:0.2)+")",0.8);})();
  plate(g,[[cx-9,370+d*0.58],[cx+9,370+d*0.58],[cx+7,388+d*0.56],[cx,395+d*0.55],[cx-7,388+d*0.56]],sM,sB,ed);
  rivet(g,cx-5,375+d*0.58,eH);rivet(g,cx+5,375+d*0.58,eH);
  joint(cx-20,366+d*0.55,8);joint(cx+20,366+d*0.55,8);

  /* ---------- ABDOMEN: ribs over a bared spine ----------
     The lean read lives here. No slab: a dark spine cavity with twin piston
     rods, and RIBS — staggered slat plates off each flank with real dark
     gaps between them. A heavy unit armors its waist; a fast one gives it
     travel and accepts the exposure. */
  g.fillStyle="#02040a";poly(g,[[cx-14,300+breath],[cx+14,300+breath],[cx+12,342+d*0.6],[cx-12,342+d*0.6]]);g.fill();
  [-1,1].forEach(function(sp){var px=cx+sp*6.5;
    pl(g,px,303+breath,px,340+d*0.6,"#0a0f18",4);
    pl(g,px-1,303+breath,px-1,340+d*0.6,offl?"#333c48":"#7e94b2",1.2);});
  [-1,1].forEach(function(s){for(var rb2=0;rb2<3;rb2++){var ry=302+rb2*12+breath;
    plate(g,[[cx+s*12,ry],[cx+s*(29-rb2*3),ry+3],[cx+s*(28-rb2*3),ry+10],[cx+s*11,ry+8]],sT,sM,ed);
    pl(g,cx+s*12,ry+1,cx+s*(28-rb2*3),ry+4,"rgba(150,172,204,"+((offl?0.08:0.22)*kf(s))+")",1);}});
  /* the heat-tile patch: the middle RIGHT rib lost its plate over the ocean
     somewhere, and what went on instead was a hand of orbital heat tiles —
     matte black squares in a grid nothing else on the fleet has, edges
     charred from the one reentry they did. History as material. */
  (function(){var ty0=316+breath;
    for(var hr2=0;hr2<2;hr2++)for(var hc2=0;hc2<3;hc2++){
      var tx4=cx+14+hc2*5.5, ty4=ty0+hr2*5.5;
      g.fillStyle=hr2+hc2===0?"#131417":"#1a1b1f";g.fillRect(tx4,ty4,4.6,4.6);
      g.strokeStyle="rgba(60,58,54,0.8)";g.lineWidth=0.7;g.strokeRect(tx4,ty4,4.6,4.6);}
    pl(g,cx+14,ty0-0.5,cx+30,ty0-0.5,"rgba(196,150,86,0.25)",1);})();

  /* ---------- CHEST: the beef lives here now ----------
     Loop 6 verdict: the stalker read STARVED — a lean unit still needs the
     mass a hunter kills with. The chest broadens to a real slab with two
     stepped PEC plates standing proud of it, and the whole thing tapers hard
     to the waist: predator as light-heavyweight, not as scaffolding. */
  plate(g,[[cx-50,300+breath],[cx-58,246+breath],[cx-26,228+breath],[cx+26,228+breath],[cx+58,246+breath],[cx+50,300+breath]],sT,sM,ed);
  plate(g,[[cx-54,248+breath],[cx-24,232+breath],[cx+24,232+breath],[cx+54,248+breath],[cx+47,258+breath],[cx-47,258+breath]],"#2c3849","#1a2331",null);
  // pecs: two separate armour slabs, stepped forward, meeting at the slit
  [-1,1].forEach(function(s){
    plate(g,[[cx+s*8,258+breath],[cx+s*46,254+breath],[cx+s*50,282+breath],[cx+s*40,294+breath],[cx+s*8,296+breath]],"#2b3648","#161e2b",ed);
    // top edge catches the lamp; the underside throws onto the ribs
    pl(g,cx+s*10,259.5+breath,cx+s*44,255.5+breath,"rgba(168,192,226,"+((offl?0.08:0.24)*kf(s))+")",1.2);
    rivet(g,cx+s*42,258+breath,eH);rivet(g,cx+s*44,286+breath,eH);});
  g.fillStyle="rgba(0,0,0,0.3)";g.fillRect(cx-40,294+breath,80,4);
  // the pec was cut open and welded shut — seam line, stitch ticks, done cold
  pl(g,cx-38,284+breath,cx-12,279+breath,"rgba(3,6,12,0.7)",1.4);
  g.strokeStyle="rgba(150,172,204,"+(offl?0.1:0.3)+")";g.lineWidth=1;g.beginPath();
  for(var ws2=0;ws2<6;ws2++){var wx5=cx-38+ws2*4.4;
    g.moveTo(wx5,281.6+breath-ws2*0.8);g.lineTo(wx5+1.8,284.4+breath-ws2*0.8);}
  g.stroke();
  // two dents in the right pec — something hit hard and did not get through
  [[cx+28,272],[cx+37,281]].forEach(function(dn){
    g.fillStyle="rgba(0,0,0,0.32)";
    g.beginPath();g.ellipse(dn[0],dn[1]+breath,4.2,2.6,-0.4,0,7);g.fill();
    g.strokeStyle="rgba(170,192,222,"+(offl?0.08:0.2)+")";g.lineWidth=0.9;
    g.beginPath();g.ellipse(dn[0]+0.8,dn[1]+breath+1,3.4,2,-0.4,0.6,2.6);g.stroke();});
  rivet(g,cx-52,248+breath,eH);rivet(g,cx+52,248+breath,eH);
  /* loop 13, the material pass: one hard specular along the clavicle bevel —
     the surface most squarely facing the lamp — and the paint gone from the
     lips that lead. Nicks are constants: a nick is a place. */
  if(!offl)plate(g,[[cx-30,233+breath],[cx+30,233+breath],[cx+26,240+breath],[cx-26,240+breath]],"#465878","#2e3a4e",null);
  g.strokeStyle="rgba(190,208,232,"+(offl?0.12:0.3)+")";g.lineWidth=1.5;g.beginPath();
  [[-34,-2],[-6,-5],[22,-3]].forEach(function(nk){g.moveTo(cx+nk[0],230.6+breath+nk[1]*0.2);g.lineTo(cx+nk[0]+2.6,233+breath+nk[1]*0.2);});
  g.stroke();
  // bolt weep into the paint under the two clavicle rivets
  [[-52],[52]].forEach(function(wp){g.fillStyle="rgba(70,44,24,0.28)";
    poly(g,[[cx+wp[0]-1.1,250+breath],[cx+wp[0]+1.1,250+breath],[cx+wp[0]+0.5,260+breath],[cx+wp[0]-0.5,260+breath]]);g.fill();});
  // GX-07, stencilled as blocks — at cell size a glyph is mush, a block still marks
  g.save();g.globalAlpha=offl?0.25:0.5;
  g.fillStyle="#c9a227";g.fillRect(cx-40,262+breath,3,10);g.fillRect(cx-34,262+breath,3,10);
  g.fillStyle="rgba(201,162,39,0.6)";g.fillRect(cx-40,274.5+breath,9,2);
  g.restore();

  /* ---- THE SPINE SLIT ----
     claude carries an octagon furnace, kimi a caged firebox. grok's light is
     a narrow vertical blade of purple down the sternum, in a recess, crossed
     by two armour bridges — the glow leaks around hard metal, never through.
     Thin, because everything on this unit is thin. */
  RB.fillStyle="#03060c";rr(RB,cx-6,252+breath,12,46,2);RB.fill();
  RB.strokeStyle=ed;RB.lineWidth=1.2;rr(RB,cx-6,252+breath,12,46,2);RB.stroke();
  [RB,RE].forEach(function(c2){ if(offl){c2.fillStyle="#161b22";c2.fillRect(cx-3,256+breath,6,38);
      // a dead core is an ember, not a void — the last heat pools at the base
      c2.fillStyle="rgba(120,44,18,0.4)";c2.fillRect(cx-2,288+breath,4,5);return;}
    var cg=c2.createLinearGradient(0,254+breath,0,296+breath);
    cg.addColorStop(0,pu(0.35));cg.addColorStop(0.5,puh(pulse));cg.addColorStop(1,pu(0.35));
    c2.fillStyle=cg;c2.fillRect(cx-3,256+breath,6,38);});
  [268,283].forEach(function(by){
    plate(g,[[cx-6.5,by+breath],[cx+6.5,by+breath],[cx+6.5,by+3.6+breath],[cx-6.5,by+3.6+breath]],sT,sB,null);
    if(!offl){RE.save();RE.globalCompositeOperation="destination-out";RE.fillRect(cx-6.5,by+breath-0.5,13,4.6);RE.restore();}});
  if(!offl){RB.save();RB.globalCompositeOperation="lighter";
    // the core's bounce must TOUCH the plates around the slit — the glow is
    // the proof the metal is near a light, not a sticker over it
    var bounce=RB.createRadialGradient(cx,275+breath,3,cx,275+breath,72);
    bounce.addColorStop(0,pu(0.34*pulse));bounce.addColorStop(0.5,pu(0.12*pulse));bounce.addColorStop(1,pu(0));
    RB.fillStyle=bounce;RB.beginPath();RB.arc(cx,275+breath,72,0,7);RB.fill();RB.restore();}

  // ---------- COLLAR + fighter neck + TRAPS ----------
  /* the trapezius wedges: two sloped slabs climbing from the collar toward
     the pauldron crowns. This is the anatomy that says the shoulders are
     PULLED UP by muscle rather than just drawn high — the hunch stops being
     a posture and becomes a build. */
  [-1,1].forEach(function(s){
    plate(g,[[cx+s*10,226+breath],[cx+s*36,232+breath],[cx+s*46,242+breath],[cx+s*12,240+breath]],"#2b3648","#161e2b",ed);
    pl(g,cx+s*11,227.5+breath,cx+s*34,233+breath,"rgba(168,192,226,"+((offl?0.08:0.22)*kf(s))+")",1.1);});
  plate(g,[[cx-26,232+breath],[cx+26,232+breath],[cx+19,244+breath],[cx-19,244+breath]],sT,sM,ed);
  plate(g,[[cx-11,216+breath],[cx+11,216+breath],[cx+9,234+breath],[cx-9,234+breath]],sM,sB,null);
  // the neck is two corded tendons under load — short, forward-set, sunk
  [-1,1].forEach(function(s){tendon(hcx+s*5,hby+60,cx+s*8,232+breath,3.6);});

  // ---------- ARMS: reach, not weight ----------
  var handR;
  function arm(sgn,mode){
    var sx=cx+sgn*47, sy=248+breath;
    joint(sx,sy+7,11);
    function P(pts){return pts.map(function(p){return [sx+sgn*p[0],sy+p[1]];});}
    // upper arm: bare mechanism — twin rods from the socket, no plate at all
    var ex,ey;
    if(mode==='reach'){ex=sx+sgn*22;ey=sy+34;}
    // hanging: elbow flexed and held a touch OUTBOARD — a coiled hang, not a
    // plumb line, and the silhouette gap it opens is what keeps the forearm
    // readable across the tasset line
    else {ex=sx+sgn*11;ey=294+d*0.6;}
    /* loop 7: the upper arm gets MEAT — an armoured biceps plate carrying
       real width from the socket to the elbow. The tendon stays strung on
       the inner line, exposed: muscle first, wiring still visible. */
    tendon(sx-sgn*4,sy+14,ex-sgn*3,ey-4,3.4);
    limbSeg(g,sx+sgn*3,sy+11,ex+sgn*1,ey-5,11,8.5,sT,sM);
    pl(g,sx+sgn*7,sy+14,ex+sgn*4,ey-8,"rgba(150,172,204,"+(offl?0.08:0.2)+")",1);
    // pauldron: a swept blade riding HIGH — the raised shoulder is the hunch,
    // and the hunch is the stalk. Bolted over the socket, spike trailing out.
    plate(g,P([[-19,-15],[3,-28],[29,-17],[42,3],[27,13],[8,6],[-12,8]]),sT,sM,ed);
    // second slat under the blade — the refs layer armour, one plate is a lid
    plate(g,P([[-14,6],[10,4],[26,10],[30,17],[12,20],[-8,15]]),sM,sB,ed);
    // crown facet: the blade's top face as an OPAQUE palette step (never an
    // alpha sheet) — the left crown takes the key, the right sits a step down
    plate(g,P([[-19,-15],[3,-28],[29,-17],[21,-12],[-14,-10]]),
      offl?(sgn<0?"#2b3446":"#262e40"):(sgn<0?"#4a5c7e":"#3b4c6a"),
      offl?"#1a212e":(sgn<0?"#2c3850":"#273349"),ed);
    pl(g,sx+sgn*21,sy-14,sx+sgn*27,sy+1,rc,1.2);
    rivet(g,sx-sgn*7,sy-5,eH);rivet(g,sx+sgn*14,sy-2,eH);
    if(sgn>0){ // a bite out of the right blade's trailing spike — silhouette
      // damage: the cut OPENS to the edge (a cut that closes strands a
      // detached sliver of blade in the air), tear lips bright
      g.save();g.globalCompositeOperation="destination-out";
      poly(g,[[sx+29,sy+2],[sx+46,sy+3],[sx+32,sy+15]]);g.fill();g.restore();
      pl(g,sx+29.5,sy+2.5,sx+40,sy+3,"rgba(170,192,222,"+(offl?0.12:0.32)+")",1);
      pl(g,sx+29.5,sy+2.5,sx+32,sy+14,"rgba(170,192,222,"+(offl?0.1:0.26)+")",1);}
    if(sgn<0){ // a chip out of the leading crown edge — cut to transparency,
      // torn lip bright: the left blade blocked something once
      g.save();g.globalCompositeOperation="destination-out";
      poly(g,[[sx-14,sy-22],[sx-7,sy-25],[sx-9,sy-19]]);g.fill();g.restore();
      pl(g,sx-13.5,sy-21.5,sx-9,sy-19.5,"rgba(190,208,232,"+(offl?0.14:0.4)+")",1.1);}
    if(sgn<0){ // reentry plasma streaks rake the LEFT blade — the flight
      // history, kept as an albedo scar: heat-darkened tracks with a
      // straw-anodized lip, angled the way the airflow went
      g.save();g.globalAlpha=offl?0.5:0.85;
      for(var ps2=0;ps2<3;ps2++){var psy=sy-16+ps2*7;
        pl(g,sx-16+ps2*3,psy,sx+14-ps2*2,psy+4.5,"rgba(30,22,20,0.5)",2.4);
        pl(g,sx-16+ps2*3,psy-1,sx+14-ps2*2,psy+3.5,"rgba(196,150,86,0.2)",0.9);}
      g.restore();}
    // contact shadow under the blade's lower rim
    g.fillStyle="rgba(0,0,0,0.26)";poly(g,P([[-7,6],[5,4],[17,10],[12,15],[-4,13]]));g.fill();
    /* the talon: a HAND, not a stub — knuckle block with a lit top face,
       three segmented digits (two phalanx plates each, tapering, tips bare
       metal), and an opposable thumb-spur on the inner line. Same machine in
       every pose; `open` is the dead splay. Digits carry real width and the
       key lands per-side — this is the thing the whole arm exists to aim. */
    function claw(x,y,open){
      var K=kf(sgn);
      // thumb-spur first — inner side, hooked in toward the work; drawn
      // under the palm so the block reads as gripping over it
      var ti=-sgn, tdy=open?5:0;
      plate(g,[[x+ti*8,y+3],[x+ti*17,y+10+tdy],[x+ti*13,y+18+tdy],[x+ti*6.5,y+9]],sT,sB,null);
      g.fillStyle="rgba(190,208,232,"+(offl?0.16:0.34)+")";
      poly(g,[[x+ti*12.5,y+12+tdy],[x+ti*14.5,y+9+tdy],[x+ti*11,y+16+tdy]]);g.fill();
      // knuckle block: palm slab, then the top face as an opaque palette step
      plate(g,[[x-12,y],[x+12,y],[x+10.5,y+10],[x-10.5,y+10]],sM,sB,ed);
      plate(g,[[x-12,y],[x+12,y],[x+10,y+4],[x-10,y+4]],
        offl?(sgn<0?"#2b3446":"#252e40"):(sgn<0?"#46587a":"#3b4c6a"),sM,null);
      rivet(g,x-5,y+6,eH);rivet(g,x+5,y+6,eH);
      // three talon digits, slightly splayed off the knuckle row
      [-1,0,1].forEach(function(f){
        var sp=f*(open?5.2:2), rx=x+f*7.4;
        var mx3=rx+sp*0.6, my3=y+9+(open?10:12);        // mid knuckle
        var tx3=rx+sp*1.2-(open?0:f*0.6), ty3=my3+(open?8:10); // tip
        // proximal phalanx — real width, one palette step UP off the thigh
        // it hangs against: the value gap is the separation
        plate(g,[[rx-4,y+9],[rx+4,y+9],[mx3+3,my3],[mx3-3,my3]],
          offl?(sgn<0?"#28303f":"#232c3c"):(sgn<0?"#3e4e6a":"#354460"),sM,null);
        pl(g,mx3-2.4,my3,mx3+2.4,my3,rc,1);            // knuckle shadow-line
        // distal phalanx — curving to the point
        plate(g,[[mx3-2.8,my3],[mx3+2.8,my3],[tx3+1.1,ty3],[tx3-1.1,ty3]],sM,sB,null);
        // bare-metal tip: paint never survives the business end
        g.fillStyle="rgba(190,208,232,"+(offl?0.2:0.42)+")";
        poly(g,[[tx3-1.3,ty3-3],[tx3+1.3,ty3-3],[tx3,ty3+1.5]]);g.fill();
        // the key catches each digit's LEFT face
        pl(g,rx-2.4,y+9,mx3-1.7,my3-1,"rgba(186,205,238,"+((offl?0.08:0.28)*K)+")",1.1);
      });}
    if(mode==='reach'){ /* the working pose, fleet rule: ONE arm leaves the
      hang, and it leaves as a SIMPLE STRETCHED REACH at the work in front —
      the claude arm. The elbow lands OUTBOARD of the waist edge in open air
      (the claude trick — the forearm must ENTER the silhouette, an arm that
      lives on the torso reads as a clutch), then the long forearm drives
      down and IN to present the closed claw at mid-torso, well clear of the
      hip line. No splay and no raised talon: a working claw grips its tool,
      it does not display. The tool rides the claw — torch in builder, the
      room device everywhere else (drawn off handR, after the arm). */
      var hx3=ex-sgn*36, hy3=ey+38;
      limbSeg(g,ex,ey,hx3,hy3-8,8.5,13,sT,sM);
      tendon(ex-sgn*2,ey+2,hx3+sgn*4,hy3-10,3);
      joint(ex,ey-1,6.5);
      /* the claw hangs IN FRONT of the waist: cast its shadow onto the torso
         first (down-right, off the upper-left key) so the digits read against
         a dark gap — the hanging hand's thigh trick, moved up a joint. */
      g.save();g.globalCompositeOperation="source-atop";g.fillStyle="rgba(2,4,9,0.4)";
      poly(g,[[hx3-sgn*15,hy3-4],[hx3-sgn*5,hy3-8],[hx3-sgn*1,hy3+18],[hx3-sgn*11,hy3+22]]);g.fill();
      g.restore();
      // wrist clamp: the claw is a separate machine, banded on (hang parity)
      plate(g,[[hx3-9,hy3-12],[hx3+9,hy3-12],[hx3+8.5,hy3-6],[hx3-8.5,hy3-6]],sT,sM,ed);
      claw(hx3,hy3-6,false);
      if(ROOM==="builder"){ // torch exits outboard: the arc lands over the rig
        plate(g,[[hx3-sgn*2,hy3+2],[hx3+sgn*10,hy3-3],[hx3+sgn*14,hy3+2],[hx3+sgn*2,hy3+9]],"#2a3444","#12181f","#3d4c63");
        handR={x:hx3+sgn*12,y:hy3+2};
      } else handR={x:hx3,y:hy3+2};
    } else { // hanging — the forearm rakes IN off the outboard elbow, the
      // wrist dropping to mid-thigh: the talon hangs BELOW and CLEAR of the
      // pelvis cluster, read against the thigh by a value step, not luck.
      // In the coil the hang is SHORT — knuckles never reach the knee line.
      var wx=sx+sgn*10, wy=356+d*0.5;
      limbSeg(g,ex,ey,wx,wy,8.5,11.5,sT,sM);
      // bracer fin off the outer flare, riding the forearm's line
      plate(g,[[wx+sgn*13,wy-36],[wx+sgn*21,wy-22],[wx+sgn*12,wy-12]],sM,sB,ed);
      // tendon strung the length of the forearm INTO the knuckle block —
      // under tension even at rest: the claw is always loaded
      tendon(ex+sgn*4,ey+6,wx+sgn*4,wy+2,3);
      pl(g,ex-sgn*4,ey+8,wx-sgn*6,wy-6,rc,1);
      /* the hand hangs IN FRONT of the quad: cast its shadow onto the thigh
         first (down-right, off the upper-left key), so digits read against a
         dark gap, never interleaved with leg plate. source-atop — the shadow
         lands on the thigh, never widens the silhouette. */
      g.save();g.globalCompositeOperation="source-atop";g.fillStyle="rgba(2,4,9,0.4)";
      poly(g,[[wx-sgn*16,wy+4],[wx-sgn*8,wy+4],[wx-sgn*10,wy+26],[wx-sgn*18,wy+22]]);g.fill();
      g.restore();
      // wrist clamp: the claw is a separate machine, banded on
      plate(g,[[wx-9.5,wy-2],[wx+9.5,wy-2],[wx+9,wy+4],[wx-9,wy+4]],sT,sM,ed);
      rivet(g,wx-6,wy+1,eH);rivet(g,wx+6,wy+1,eH);
      joint(ex,ey-1,8);
      // the hanging talon rests CLOSED in every live state — the resting
      // hand is identical idle or working (the operator's rule); only the
      // dead splay opens it
      claw(wx,wy+3,offl);
      joint(wx,wy,5.5);
      /* kill tallies, scratched into the LEFT forearm's flat — counted where
         they were made, read when the arm hangs. Worn gold, same paint life
         as the stencil. */
      if(sgn<0){g.save();g.globalAlpha=offl?0.25:0.5;g.fillStyle="#c9a227";
        for(var tl2=0;tl2<4;tl2++)g.fillRect(wx-6+tl2*3,wy-32,1.6,7);
        g.restore();}
      // idle anchor only — never steal the anchor from the working reach
      // (the right arm hangs THROUGH work now, and it draws after the left)
      if(sgn>0&&!handR)handR={x:wx,y:wy+16};
    }
  }
  /* The rooms park a readout on the right half of the bench, exactly where a
     right-handed weld lands (the kimi round-9 verdict). grok works LEFT-handed
     in EVERY room, and the right arm never leaves the idle hang — one moving
     arm per unit is the fleet rule (claude raises one, kimi flexes one,
     codex lifts one palp). */
  arm(-1, work?'reach':'down');
  arm(1, 'down');
  if(work&&ROOM!=="builder"&&handR){var h=handR;
    if(ROOM==="reviewer"){ plate(g,[[h.x-3,h.y-9],[h.x+17,h.y-11],[h.x+17,h.y+2],[h.x-3,h.y+4]],"#1a2836","#0c1620","#3a5570");
      [RB,RE].forEach(function(c2){if(!offl){c2.fillStyle=rgba(130,205,255,0.75);c2.fillRect(h.x+1,h.y-7,11,7);}}); }
    else { plate(g,[[h.x-2,h.y-11],[h.x+9,h.y-13],[h.x+12,h.y+4],[h.x+1,h.y+6]],"#241a30","#140e1c","#4a3a5e");
      [RB,RE].forEach(function(c2){if(!offl){c2.fillStyle=rgba(201,139,255,0.75);c2.fillRect(h.x+2,h.y-9,4,5);}}); }
  }

  /* ---------- HEAD: the mask IS the skull ----------
     Not a face, and not a helmet worn over one — a machined structure whose
     built-in geometry does what the predator's mask does: a broad crown, one
     heavy brow ridge overhanging two deep-set optics, cheek ridges flaring
     outward toward the jaw, and a vented, chipped chin that has been hit and
     kept. The head sits LOW, sunk to the collar between raised pauldron
     crowns: that sink is the hunch, and the hunch is the stalk. */
  /* the mask must WIN the thumbnail: head plates run ONE palette step up the
     lamp (the legs' trick) — opaque steps, no wash. The brow recess stays
     dark so the optics stay deep-set; the step is what beats the sternum. */
  var hT=offl?"#1f2531":"#313e53", hM=offl?"#141a25":"#1b2432",
      hBr=offl?"#28303d":"#405169", hBrB=offl?"#1b222d":"#243043";
  // skull
  plate(g,[[hcx-24,hby+24],[hcx-21,hby+8],[hcx-10,hby],[hcx+10,hby],[hcx+21,hby+8],[hcx+24,hby+24],[hcx+18,hby+46],[hcx+10,hby+56],[hcx-10,hby+56],[hcx-18,hby+46]],hT,hM,ed);
  /* the slick-back: the crown is not armour, it is CABLE — a cap of combed
     rows swept front-to-back, socketed into an anchor band at the hairline.
     The silhouette gets small scallops where the rows crest. */
  g.fillStyle="#0b0e14";
  poly(g,[[hcx-19,hby+9],[hcx-9,hby+1],[hcx+9,hby+1],[hcx+19,hby+9],[hcx+15,hby+14],[hcx-15,hby+14]]);g.fill();
  [-2,-1,0,1,2].forEach(function(ci2){var bx=hcx+ci2*6;
    g.strokeStyle="#333b48";g.lineWidth=1;
    g.beginPath();g.moveTo(bx,hby+13);g.quadraticCurveTo(bx+ci2*1.6,hby+7,bx+ci2*3,hby+2.5);g.stroke();});
  // scalloped crest along the top edge — cable rows cresting, kept low
  g.strokeStyle="#0b0e14";g.lineWidth=2.2;g.beginPath();
  [-1.5,-0.5,0.5,1.5].forEach(function(sc4){g.moveTo(hcx+sc4*8-3,hby+1);g.quadraticCurveTo(hcx+sc4*8,hby-1.6,hcx+sc4*8+3,hby+1);});
  g.stroke();
  // slicked cable takes a sheen the way brushed plate does not — one soft
  // band across the crown, keyed to the lamp
  g.fillStyle="rgba(186,205,238,"+(offl?0.05:0.13)+")";
  poly(g,[[hcx-15,hby+8],[hcx-8,hby+2],[hcx+8,hby+2],[hcx+15,hby+8],[hcx+11,hby+10.5],[hcx-11,hby+10.5]]);g.fill();
  /* the crown wears TEETH: short conical spikes rimming the dome, temple to
     temple — the mask reference's silhouette is spiked, not smooth. Each cone
     leans outward the way it sits on the curve; lit face left. */
  [[-21,10],[-16,3],[-9,-1.5],[0,-3],[9,-1.5],[16,3],[21,10]].forEach(function(sk){
    var sxk=hcx+sk[0], syk=hby+sk[1], dx4=sk[0]*0.16, ln4=6.5-Math.abs(sk[0])*0.06;
    poly(g,[[sxk-2,syk+1.5],[sxk+2,syk+1.5],[sxk+dx4,syk-ln4]]);
    g.fillStyle="#141a26";g.fill();
    g.strokeStyle=ed;g.lineWidth=0.8;
    poly(g,[[sxk-2,syk+1.5],[sxk+2,syk+1.5],[sxk+dx4,syk-ln4]]);g.stroke();
    pl(g,sxk-1.6,syk+1,sxk+dx4-0.4,syk-ln4+1,"rgba(170,192,222,0.3)",0.8);});
  // center ridge, and the trident carve at the forehead — the mark of the mask
  pl(g,hcx,hby-1,hcx,hby+14,"#0a0f18",2.8);
  pl(g,hcx-0.9,hby,hcx-0.9,hby+13,"rgba(170,192,222,"+(offl?0.1:0.26)+")",0.9);
  pl(g,hcx,hby+9,hcx-5,hby+3,"#0a0f18",1.6);pl(g,hcx,hby+9,hcx+5,hby+3,"#0a0f18",1.6);
  // the anchor band the mane sockets into
  pl(g,hcx-14,hby+14,hcx+14,hby+14,rc,1.2);
  rivet(g,hcx-10,hby+12,eH);rivet(g,hcx+10,hby+12,eH);
  // brow ridge: one heavy chevron, overhanging
  plate(g,[[hcx-19,hby+27],[hcx,hby+31],[hcx+19,hby+27],[hcx+15,hby+15],[hcx-15,hby+15]],hBr,hBrB,ed);
  pl(g,hcx,hby+15,hcx,hby+30,rc,1);
  // the recess the brow shades — deepest right under the ridge
  RB.fillStyle="#03060d";poly(RB,[[hcx-17,hby+27],[hcx+17,hby+27],[hcx+15,hby+41],[hcx-15,hby+41]]);RB.fill();
  var bs=RB.createLinearGradient(0,hby+26,0,hby+38);bs.addColorStop(0,"rgba(0,0,0,0.85)");bs.addColorStop(1,"rgba(0,0,0,0)");
  RB.fillStyle=bs;poly(RB,[[hcx-17,hby+26],[hcx+17,hby+26],[hcx+16,hby+36],[hcx-16,hby+36]]);RB.fill();
  // nose bridge between the optics — mask geometry, not anatomy
  plate(g,[[hcx-3,hby+28],[hcx+3,hby+28],[hcx+2,hby+42],[hcx-2,hby+42]],sM,sB,null);
  /* the GLARE: two canted wedge slits, swept up-and-out under the brow — the
     mask reference's narrowed eyes, not a pair of round lamps. Sockets first:
     dark wedges cut deeper than the recess. Hot at the inner corner, the slit
     tapers as it climbs. Idle both breathe together; working both burn.
     Dead: grey ticks, one ember. */
  [-1,1].forEach(function(s){var oy=hby+33;
    g.fillStyle="#01030a";
    poly(g,[[hcx+s*3.5,oy+1],[hcx+s*16,oy-4],[hcx+s*17,oy+1],[hcx+s*4.5,oy+4.5]]);g.fill();
    [RB,RE].forEach(function(c2){ if(offl){c2.fillStyle="#20262e";
        poly(c2,[[hcx+s*5,oy+1.5],[hcx+s*14,oy-1.5],[hcx+s*14,oy+0.5],[hcx+s*5,oy+3]]);c2.fill();
        if(s<0){c2.fillStyle="rgba(120,44,18,0.4)";c2.fillRect(hcx+s*7,oy+0.8,2.4,1.4);}return;}
      var scn=0.66+0.2*Math.sin(t*2.1);
      var br2=work?(0.85+0.15*Math.sin(t*9+s)):scn;
      c2.fillStyle=pu(0.6*br2);
      poly(c2,[[hcx+s*4,oy+0.8],[hcx+s*15.5,oy-3.2],[hcx+s*16,oy+0.6],[hcx+s*4.5,oy+3.8]]);c2.fill();
      c2.fillStyle=puh(0.95*br2);
      poly(c2,[[hcx+s*4.5,oy+1.2],[hcx+s*12,oy-1.2],[hcx+s*12,oy+1],[hcx+s*5,oy+3]]);c2.fill();
      // inner-corner burn: the hottest point sits by the nose — the scowl
      var eg=c2.createRadialGradient(hcx+s*6,oy+1.8,0.4,hcx+s*6,oy+1.8,4.5);
      eg.addColorStop(0,puh(0.9*br2));eg.addColorStop(1,pu(0));
      c2.fillStyle=eg;c2.beginPath();c2.arc(hcx+s*6,oy+1.8,4.5,0,7);c2.fill();});});
  // cheek ridges: flaring OUT toward the jaw — the mandible echo, built in
  [-1,1].forEach(function(s){
    plate(g,[[hcx+s*20,hby+27],[hcx+s*12,hby+43],[hcx+s*16,hby+61],[hcx+s*26,hby+50]],hT,sB,ed);
    plate(g,[[hcx+s*26,hby+50],[hcx+s*31,hby+58],[hcx+s*17,hby+61]],hT,sB,null);
    // second ridge line inside the sweep — the cheek is layered, not a fin
    pl(g,hcx+s*17,hby+33,hcx+s*13,hby+46,rc,1);
    pl(g,hcx+s*20,hby+28,hcx+s*13,hby+43,"rgba(150,172,204,"+((offl?0.1:0.26)*kf(s))+")",1);
    rivet(g,hcx+s*17,hby+39,eH);});
  // the chin: wide, vented, and it has been HIT — a chip out of the left
  // lip, cut to transparency, torn edge bright; weld stitches where the jaw
  // was re-seated after
  /* the MOUTH PIECE: not a chin — a muzzle. It projects: wide at the cheeks,
     tapering to a blunt snout well below the old jaw line, split by a center
     ridge and wrapped in segment grooves like the mask's wrinkled lip armor. */
  plate(g,[[hcx-14,hby+44],[hcx+14,hby+44],[hcx+15,hby+56],[hcx+10,hby+68],[hcx+6,hby+76],[hcx-6,hby+76],[hcx-10,hby+68],[hcx-15,hby+56]],hT,hM,ed);
  // center ridge — the beak line, lit on the key side
  pl(g,hcx,hby+45,hcx,hby+74,"#0a0f18",2.8);
  pl(g,hcx-1,hby+46,hcx-1,hby+73,"rgba(170,192,222,"+(offl?0.1:0.28)+")",0.9);
  // segment grooves: the muzzle is plated in bands, each lip catching light
  [[56,13],[63,10],[69,7.5]].forEach(function(gr){
    pl(g,hcx-gr[1],hby+gr[0],hcx+gr[1],hby+gr[0],"rgba(3,6,12,0.8)",1.6);
    pl(g,hcx-gr[1]+1,hby+gr[0]+1.2,hcx+gr[1]-1,hby+gr[0]+1.2,"rgba(150,172,204,"+(offl?0.06:0.16)+")",0.8);});
  // the snout lip
  pl(g,hcx-5,hby+74.8,hcx+5,hby+74.8,"rgba(170,192,222,"+(offl?0.1:0.3)+")",1.2);
  RB.fillStyle=rc;for(var vs=0;vs<3;vs++)RB.fillRect(hcx-6.5+vs*5,hby+48.5,3.4,6);
  // breath soot: the vents exhale onto the chin below them, and it stays
  g.save();g.globalAlpha=offl?0.5:0.8;g.fillStyle="rgba(24,20,18,0.35)";
  for(var st2=0;st2<3;st2++)poly(g,[[hcx-6+st2*5,hby+55],[hcx-3.6+st2*5,hby+55],[hcx-4+st2*5,hby+61],[hcx-5.6+st2*5,hby+61]]),g.fill();
  g.restore();
  g.save();g.globalCompositeOperation="destination-out";
  poly(g,[[hcx-14.5,hby+58],[hcx-8.5,hby+60],[hcx-11.5,hby+66]]);g.fill();g.restore();
  pl(g,hcx-14.5,hby+58,hcx-11.5,hby+66,"rgba(170,192,222,"+(offl?0.14:0.34)+")",1);
  g.strokeStyle="rgba(150,172,204,"+(offl?0.12:0.3)+")";g.lineWidth=1;
  g.beginPath();for(var wj=0;wj<4;wj++){var wx2=hcx+3+wj*2.6;g.moveTo(wx2,hby+45);g.lineTo(wx2+1.4,hby+47.6);}g.stroke();
  /* THE CLAW MARKS. Three gouges raked across the mask by something with
     talons of its own — and CARVED, not painted: each is a dark trench with
     a torn lip thrown up on the light side, burrs of displaced metal along
     the cut, and a bitten notch where it enters or leaves a plate edge. They
     cross brow, socket line, cheek and muzzle — whatever was in the way. */
  (function(){
    var GOUGE=[ [[2,13],[12,26],[22,44]],
                [[-4,20],[7,38],[16,56]],
                [[-10,28],[1,46],[8,61]] ];
    GOUGE.forEach(function(gp,gi){
      var a=[hcx+gp[0][0],hby+gp[0][1]],b=[hcx+gp[1][0],hby+gp[1][1]],c=[hcx+gp[2][0],hby+gp[2][1]];
      // under-shadow of the whole wound
      g.strokeStyle="rgba(0,0,0,0.35)";g.lineWidth=4.2-gi*0.5;
      g.beginPath();g.moveTo(a[0]+1,a[1]+1);g.quadraticCurveTo(b[0]+1,b[1]+1,c[0]+1,c[1]+1);g.stroke();
      // the trench
      g.strokeStyle="rgba(2,5,10,0.92)";g.lineWidth=2.6-gi*0.3;
      g.beginPath();g.moveTo(a[0],a[1]);g.quadraticCurveTo(b[0],b[1],c[0],c[1]);g.stroke();
      // torn lip on the key side of the cut
      g.strokeStyle="rgba(186,205,238,"+(offl?0.16:0.42)+")";g.lineWidth=1;
      g.beginPath();g.moveTo(a[0]-1.2,a[1]-1);g.quadraticCurveTo(b[0]-1.2,b[1]-1,c[0]-1.2,c[1]-1);g.stroke();
      // burrs: displaced metal standing off the cut
      [0.3,0.62].forEach(function(bt){
        var bx3=(1-bt)*(1-bt)*a[0]+2*bt*(1-bt)*b[0]+bt*bt*c[0],
            by3=(1-bt)*(1-bt)*a[1]+2*bt*(1-bt)*b[1]+bt*bt*c[1];
        g.fillStyle="rgba(190,208,232,"+(offl?0.1:0.3)+")";
        g.fillRect(bx3+1.4,by3-0.6,1.6,1.2);});
      // entry notch: the plate edge it broke on the way in
      g.fillStyle="rgba(2,5,10,0.85)";
      poly(g,[[a[0]-1.8,a[1]-1.8],[a[0]+2,a[1]-0.6],[a[0]+0.4,a[1]+2]]);g.fill();
      g.fillStyle="rgba(186,205,238,"+(offl?0.12:0.32)+")";
      poly(g,[[a[0]-2.2,a[1]-2.2],[a[0]-0.4,a[1]-1.6],[a[0]-1.6,a[1]-0.4]]);g.fill();
    });})();
  // the jaw throws onto the neck cords below it
  cavity(g,hcx-11,hby+72,22,8,0.4);

  /* ---------- THE MANE, front layer ----------
     Two dreads a side fall in FRONT of the shoulders, drawn after the head so
     they ride over the cheek ridges. Live they hang clear of the mask; dead
     they swing inward and spill OVER it — the face disappears behind its own
     hair, which is the strongest "nobody home" this unit can say. And the
     right outer dread is SEVERED mid-length, the stump cauterized bright:
     something got a grip on it once. Once. */
  var FRONTC=[[-1,21,37,274],[-1,24,44,288],[1,21,37,274],[1,24,0,0]];
  FRONTC.forEach(function(cb,ci){var s=cb[0], ax=hcx+s*cb[1], ay=hby+16, cut=(ci===3);
    var tx,ty,c1x,c1y;
    if(cut){tx=hcx+s*26;ty=hby+44;c1x=hcx+s*25;c1y=hby+26;}
    else if(offl){tx=hcx+s*(6+(ci%2)*5);ty=hby+62+(ci%2)*6;c1x=hcx+s*15;c1y=hby+34;}
    else {tx=cx+s*cb[2];ty=cb[3]+sway*2*(ci%2?-1:1);c1x=hcx+s*(cb[1]+17);c1y=hby+26;}
    var c2x=cut?tx+s*3:tx+s*7, c2y=cut?(ty+hby+28)/2:(ty+hby+72)/2;
    var hi=offl?"#20242c":(s<0?"#4e5a6e":"#242b36");
    cable(ax,ay,c1x,c1y,c2x,c2y,tx,ty,cut?5.4:5.6,cut?4.2:2.8,hi);
    if(cut){ // the stump: a blunt cauterized ferrule HARD against the cable
      // end — nothing hangs off it; the shorter-than-its-mirror cable
      // carries the story alone
      g.fillStyle="#10151d";rr(g,tx-2.6,ty-1.5,5.2,4,1);g.fill();
      g.strokeStyle=ed;g.lineWidth=1;rr(g,tx-2.6,ty-1.5,5.2,4,1);g.stroke();
      pl(g,tx-2,ty+2.2,tx+2,ty+2.2,"rgba(170,192,222,"+(offl?0.12:0.3)+")",1);
    } else {
      // ferrule terminus, SEATED: the tip rests on chest plate — a contact
      // shadow under the weight, or the ferrule reads as pasted on
      g.fillStyle="rgba(2,4,9,0.5)";
      g.beginPath();g.ellipse(tx,ty+7.5,4.6,2,0,0,7);g.fill();
      g.fillStyle="#10151d";rr(g,tx-2.7,ty,5.4,7,1);g.fill();
      g.strokeStyle=ed;g.lineWidth=1;rr(g,tx-2.7,ty,5.4,7,1);g.stroke();
      pl(g,tx-2.7,ty+0.8,tx+2.7,ty+0.8,"rgba(150,172,204,"+((offl?0.08:0.22)*kf(s))+")",1);
      if(ci!==1)litBar(tx,ty+3.2,5.4);
    }});

  /* the mane is OVER the shoulders, so it must THROW: each front dread casts
     a soft dark onto the pauldron crown it crosses, biased down-right off the
     upper-left key. source-atop — lands on plate, never widens the
     silhouette. Dead the dreads spill inboard and cross nothing. */
  if(!offl){g.save();g.globalCompositeOperation="source-atop";g.fillStyle="rgba(2,4,9,0.28)";
    [-1,1].forEach(function(s){var sy2=248+breath;
      poly(g,[[cx+s*25+2,sy2-18],[cx+s*40+2,sy2-14],[cx+s*43+2,sy2-7],[cx+s*27+2,sy2-4]]);g.fill();});
    g.restore();}
  // crown speculars live IN the pauldron facets (opaque, in arm()) — the only
  // free lamp note left up here is the brow band
  g.fillStyle="rgba(196,214,244,"+(offl?0.08:0.2)+")";
  poly(g,[[hcx-14,hby+16],[hcx+14,hby+16],[hcx+12,hby+19],[hcx-12,hby+19]]);g.fill();

  cavity(g,cx-30,296+breath,60,16,0.3);
  cavity(g,cx-24,376+d*0.55,48,20,0.32);
  cavity(g,cx-20,243+breath,40,13,0.28);
  stanceOff();
  buildRim(offl?[86,84,94]:[176,124,255]);      // grok: violet on the key side
  /* ONE key: the shared rim lands on right-facing edges only, and from the
     torso out those are either interior (a gap edge the lamp cannot see) or
     the fill flank — both owed ONE consistent story the offset trick cannot
     tell. Kill it from center-left out; the hand strokes own both flanks,
     and interior edges get NO rim: shadow is a story too. */
  (function(){var dg=RR.createLinearGradient(cx-70,0,cx-30,0);
    dg.addColorStop(0,"rgba(0,0,0,0)");dg.addColorStop(1,"rgba(0,0,0,1)");
    RR.save();RR.globalCompositeOperation="destination-out";
    RR.fillStyle=dg;RR.fillRect(cx-70,0,RW-(cx-70),RH);RR.restore();})();
  /* the shared rim survives only on trailing (right) edges — the declared key
     is upper-LEFT and vendor-coloured, so the key-side rim is drawn by hand.
     PER PLATE: every stroke hugs one plate's own outer edge and dies at the
     joint. The hanging arm rides OVER the thigh, so the strokes follow the
     arm stack (upper arm, forearm, fin, claw) and the thigh takes one only
     when the arm is away — a line across the stack reads as a stray wire. */
  var lHang=!work, rHang=true; // only the LEFT arm leaves the hang for the tool; the right always rests
  (function(){var kc=puh(offl?0.28:0.8);
    // arm/torso strokes live in stance space (+WS,+SD); leg strokes in world
    var sx=cx+WS-47, sy=248+SD+breath, ex=sx-11, ey=294+SD+d*0.6, wx=sx-10, wy=356+SD+d*0.5;
    var hy0=362+SD+d*0.4+breath*0.3, kx=cx-(offl?54:58), ky=452+d*0.3,
        ax=cx-45, ay=516+d*0.1, fx=cx-52;
    pl(RR,sx-4,sy-26,sx-26,sy-16,kc,2);
    pl(RR,sx-26,sy-16,sx-36,sy+1,kc,1.6);
    if(lHang){
      pl(RR,sx-11,sy+15,ex-6,ey-11,kc,1.6);            // upper arm, to the elbow
      pl(RR,ex-5,ey+8,ex+1,wy-37,kc,1.6);              // forearm, to the fin
      pl(RR,wx-11.5,wy-33,wx-16.5,wy-23,kc,1.4);       // bracer fin lead edge
      pl(RR,wx-10,wy+3,wx-8.7,wy+11,kc,1.4);           // knuckle block
      pl(RR,wx-9,wy+12,wx-9.4-(offl?2:0),wy+(offl?22:24),kc,1.2); // outer digit
    } else pl(RR,cx-33,hy0+8,kx-9,ky-9,kc,1.8);        // thigh, tasset to knee
    pl(RR,kx-11,ky-11,kx-8,ky+4,kc,1.6);               // knee guard, raked back edge
    pl(RR,kx-6,ky+14,ax-5,ay-6,kc,1.8);                // shank, below the guard
    pl(RR,ax-5,ay+2,fx-7,544,kc,1.6);
    pl(RR,fx-14,547,fx-15,553,kc,1.4);})();
  /* fill side: cool bounce off the room — SUBORDINATE to the key: ~0.14, and
     ACCENTS near each plate's crown only. A full-length lit right contour
     reads as a second lamp, and one lamp is the whole stage's story. */
  (function(){var fc="rgba(150,196,235,"+(offl?0.05:0.14)+")";
    var sx=cx+WS+47, sy=248+SD+breath, ex=sx+11, ey=294+SD+d*0.6, wx=sx+10, wy=356+SD+d*0.5;
    var hy0=362+SD+d*0.4+breath*0.3, kx=cx+(offl?54:50), ky=456+d*0.3,
        ax=cx+30, ay=518+d*0.1, fx=cx+38;
    var hcx2=hcx+WS, hby2=hby+SD;
    pl(RR,hcx2+20,hby2+30,hcx2+22,hby2+38,fc,1.1);     // cheek ridge, upper flare only
    RR.strokeStyle=fc;RR.lineWidth=1.1;RR.beginPath(); // outermost rear cable, crown reach only
    RR.moveTo(hcx2+17,hby2+10);
    RR.quadraticCurveTo(hcx2+28,hby2+21,hcx2+36,hby2+38);
    RR.stroke();
    pl(RR,sx+6,sy-25,sx+19,sy-19,fc,1.4);              // crown outer edge, top run
    pl(RR,sx+27,sy-15,sx+32,sy-7,fc,1.2);              // trailing spike root
    if(rHang){
      pl(RR,sx+11,sy+15,sx+13,sy+34,fc,1.2);           // biceps crown
      pl(RR,ex+5,ey+8,ex+3,ey+22,fc,1.2);              // forearm, off the elbow only
      pl(RR,wx+11.5,wy-33,wx+16.5,wy-23,fc,1.1);
      pl(RR,wx+10,wy+3,wx+8.7,wy+11,fc,1.1);
    } else pl(RR,cx+33,hy0+8,cx+36,hy0+24,fc,1.4);     // thigh crown only
    pl(RR,kx+9,ky-9,kx+15,ky+1,fc,1.4);                // knee spike root
    pl(RR,kx+6,ky+14,kx+3,ky+30,fc,1.4);               // shank, calf swell only
    pl(RR,ax+5,ay+2,ax+7,ay+13,fc,1.2);})();           // metatarsal crown
  // deck rule: NO rim inside the last 8 units above the sole — a lit edge at
  // the contact row reads as glow, and the shared rim hugs the toe corners
  (function(){var fg2=RR.createLinearGradient(0,551,0,556);
    fg2.addColorStop(0,"rgba(0,0,0,0)");fg2.addColorStop(1,"rgba(0,0,0,1)");
    RR.save();RR.globalCompositeOperation="destination-out";
    RR.fillStyle=fg2;RR.fillRect(0,551,RW,RH-551);RR.restore();})();
  // anchors return in WORLD coords — the rooms and the portrait crop consume
  // them, and the stance translate is this function's private business
  var hh=handR?{x:handR.x+WS,y:handR.y+SD}:{x:cx+WS+45,y:382+SD+d*0.8};
  return {hand:hh,coreY:275+breath+SD,hy:hby+8+SD,offl:offl,work:work,
          // toes: where each claw actually meets the deck — the stage's
          // occlusion wants the contact points, not the foot's centroid
          feet:[{x:cx-52,y:560,w:30,toes:[cx-63,cx-52,cx-41]},
                {x:cx+38,y:560,w:28,toes:[cx+27,cx+38,cx+49]}]};
}

/* ===================== KIMI — hovering companion drone, screen-face (pink) ===================== */
function buildKimi(t,st){
  var offl=st==="offline", work=st==="working";
  var GX=[RB,RE,RR];for(var q=0;q<3;q++){var c0=GX[q];c0.setTransform(1,0,0,1,0,0);c0.clearRect(0,0,c0.canvas.width,c0.canvas.height);c0.setTransform(SS,0,0,SS,0,0);c0.globalAlpha=1;c0.globalCompositeOperation="source-over";c0.filter="none";}
  var cx=260, g=RB;
  /* JUGGERNAUT (KM-09X). Kimi's unit was the fleet's flying TV — one rounded
     primitive with a face, and eleven loops of polish never changed what it
     WAS. The replacement is kimi's own concept (PR #198, dev/prototypes/kimi):
     a siege torso on a nuclear torch. Three huge shapes — a bunker chest with
     a caged reactor furnace, two pauldrons that are engine cowls over grav
     bells, hammer gauntlets in an A-stance — a head buried under a chevron
     brow with one pink optic and one amber glass eye, no legs: scale-armour
     waist leaves over a vector-vane nozzle and the torch does the rest.
     Offline the torch dies and the unit settles onto its own knuckles. */
  /* 1.2 crowded the room — the pauldrons out-spanned codex's whole leg splay
     and the head ran at the lamp. 1.05 keeps the siege mass but lets the
     room breathe around it (operator: ~10-15% down, not small). */
  var F=1.05, OY=560-470*F, TA=260-260*F;
  RB.setTransform(F*SS,0,0,F*SS,TA*SS,OY*SS);RE.setTransform(F*SS,0,0,F*SS,TA*SS,OY*SS);
  function TX(x){return F*x+TA;} function TY(y){return F*y+OY;}
  var FLOORL=470;                                          // deck line in local coords (maps to sprite 560)
  /* The same war-metal claude and codex are pressed from. The prototype's
     lighter blue-grey read PALE next to them in the room — vendor identity
     lives in the lights and the rim, never in the plate. */
  var sT="#242e3d",sM="#131a25",sB="#080c13",ed="#2c3648",eH="#41506a",rc="#05080d";
  if(offl){sT="#181d25";sM="#0e131b";sB="#05080d";ed="#222932";eH="#2a323d";}
  var PK=offl?[74,80,92]:[255,114,182], PKH=offl?[120,126,138]:[255,182,214];
  /* The amber glass eye — the one place the per-vendor colour rule bends, and
     kimi's single non-negotiable from the hand-off. Offline both optics die to
     the same grey. */
  var AM=offl?[80,80,88]:[255,176,84], AMH=offl?[130,124,120]:[255,214,150];
  function pk(a){return "rgba("+PK[0]+","+PK[1]+","+PK[2]+","+a+")";}
  function pkh(a){return "rgba("+PKH[0]+","+PKH[1]+","+PKH[2]+","+a+")";}
  function bolt(c,x,y,r,lit){c.fillStyle="#05080e";c.beginPath();c.arc(x,y,r,0,7);c.fill();
    var bgr=c.createRadialGradient(x-r*0.3,y-r*0.4,0.4,x,y,r);bgr.addColorStop(0,"rgba(200,214,238,"+(lit||0.35)+")");bgr.addColorStop(1,"rgba(4,8,14,0.8)");
    c.fillStyle=bgr;c.beginPath();c.arc(x,y,r*0.66,0,7);c.fill();
    pl(c,x-r*0.34,y,x+r*0.34,y,"rgba(3,6,11,0.85)",1);}
  function seg2(c,x0,y0,x1,y1,w0,w1,top,bot,edc){var dx=x1-x0,dy=y1-y0,ln=Math.hypot(dx,dy)||1,nx=-dy/ln,ny=dx/ln;
    plate(c,[[x0+nx*w0,y0+ny*w0],[x1+nx*w1,y1+ny*w1],[x1-nx*w1,y1-ny*w1],[x0-nx*w0,y0-ny*w0]],top,bot,edc);}
  function hose(c,x0,y0,x1,y1,sag,w){
    var mx=(x0+x1)/2,my=Math.max(y0,y1)+sag;
    c.strokeStyle="rgba(12,17,25,0.98)";c.lineWidth=w;
    c.beginPath();c.moveTo(x0,y0);c.quadraticCurveTo(mx,my,x1,y1);c.stroke();
    c.strokeStyle="rgba(120,132,156,0.35)";c.lineWidth=w*0.28;
    c.beginPath();c.moveTo(x0,y0);c.quadraticCurveTo(mx,my,x1,y1);c.stroke();}
  var pulse=offl?0:(work?(0.62+0.26*Math.sin(t*6)):(0.38+0.14*Math.sin(t*2)));
  var bob=(offl||reduced)?0:Math.sin(t*1.6)*2.2;
  /* Chest centre. Powered it hangs with the gauntlets clearing the near-plane
     worktop line (~local 332) with visible air under the knuckle studs — the
     A-stance is the pose and the worktop must not bite it. Offline the torch
     dies and it drops until the knuckles land exactly on the deck — the
     offline posture IS this number. */
  var BY=offl?336:156+bob;
  var th=offl?0:(work?(0.78+0.22*Math.sin(t*11)+0.07*Math.sin(t*23)):(0.44+0.1*Math.sin(t*3)));

  /* ---- 0 · the torch (furthest plane) ----
     A siege engine does not drift down like a leaf; it hangs LOW over a
     short, violent column of fire and the deck remembers it.
     Parked, the vector vanes gimbal up and the bell tucks into the cowl:
     nozzle bottom lands at exactly the same local line as the knuckles
     (BY+134 = deck), because the hand-off's dead posture is fists AND cowl
     on the floor — and because a bell left at flight length would spear
     32px through the deck the fists rest on. */
  var nozY=BY+(offl?128:168);
  if(!offl){
    [RB,RE].forEach(function(c,ci){c.save();c.globalCompositeOperation="lighter";
      var jg=c.createLinearGradient(0,nozY,0,FLOORL-2);
      jg.addColorStop(0,pkh((ci?0.3:0.42)*th));jg.addColorStop(0.45,pk((ci?0.13:0.2)*th));jg.addColorStop(1,pk(0));
      var wb=Math.sin(t*7)*3.5;
      c.fillStyle=jg;c.beginPath();
      c.moveTo(cx-18,nozY);c.lineTo(cx+18,nozY);
      c.lineTo(cx+22+wb,FLOORL-2);c.lineTo(cx-22-wb,FLOORL-2);c.closePath();c.fill();
      if(!ci){c.fillStyle="rgba(255,240,248,"+(0.4*th)+")";
        c.beginPath();c.moveTo(cx-7,nozY);c.lineTo(cx+7,nozY);c.lineTo(cx+10+wb*0.4,FLOORL-2);c.lineTo(cx-10-wb*0.4,FLOORL-2);c.closePath();c.fill();}
      c.restore();});
    [RB,RE].forEach(function(c){c.save();c.globalCompositeOperation="lighter";
      var nz=c.createRadialGradient(cx,nozY+4,1,cx,nozY+4,22);
      nz.addColorStop(0,"rgba(255,240,248,"+(0.55*th)+")");nz.addColorStop(0.5,pk(0.3*th));nz.addColorStop(1,pk(0));
      c.fillStyle=nz;c.beginPath();c.arc(cx,nozY+4,22,0,7);c.fill();c.restore();});
  }

  /* ---- 0b · BACK: trailing power cables ----
     The same verdict claude's back reached in #195: doom units don't carry
     backpacks, they trail cables. Two per side loop out of the spine and
     dive behind the pauldron crowns — drawn before everything so the chest,
     head and cowls overlap them, and only the slack arcs show over the
     shoulder line. Offline they sag with the dead machine. */
  [-1,1].forEach(function(s2){
    var slk=offl?9:0;
    [[38,70,-135,96,5],[28,56,-122,82,3.8]].forEach(function(cb){
      var x0=cx+s2*cb[0], mx2=cx+s2*cb[1], my2=BY+cb[2]+slk, x1=cx+s2*cb[3], y1=BY-72+slk*0.6;
      g.strokeStyle="#05080e";g.lineWidth=cb[4];g.beginPath();
      g.moveTo(x0,BY-58);g.quadraticCurveTo(mx2,my2,x1,y1);g.stroke();
      g.strokeStyle=offl?"#252c37":"#4f5f78";g.lineWidth=1.3;g.beginPath();
      g.moveTo(x0,BY-58);g.quadraticCurveTo(mx2,my2,x1,y1);g.stroke();});});

  /* ---- 1 · pauldron grav bells: the glow under the armour ---- */
  [-1,1].forEach(function(sg){
    var bx=cx+sg*118,by2=BY-8;
    g.fillStyle="#04070c";g.beginPath();g.ellipse(bx,by2+26,26,13,0,0,7);g.fill();     // bell mouth
    if(!offl){var bg=0.62+0.32*pulse;
      [RB,RE].forEach(function(c){c.save();c.globalCompositeOperation="lighter";
        var rg=c.createRadialGradient(bx,by2+26,2,bx,by2+26,26);
        rg.addColorStop(0,pkh(0.4*bg));rg.addColorStop(0.5,pk(0.18*bg));rg.addColorStop(1,pk(0));
        c.fillStyle=rg;c.beginPath();c.ellipse(bx,by2+26,26,13,0,0,7);c.fill();c.restore();});}
    /* The bell is a MACHINE: four vanes turn in the mouth, faster under
       throttle, frozen mid-rotation when dead or reduced. In a still they
       read as an off-angle turbine; live they read as lift. */
    var rot=(offl||reduced)?0.5:t*(work?2.4:0.9)+sg;
    for(var v=0;v<4;v++){var va=rot+v*Math.PI/2;
      pl(g,bx,by2+26,bx+Math.cos(va)*22,by2+26+Math.sin(va)*10,"rgba(8,12,18,"+(offl?0.7:0.9)+")",3);}
    g.fillStyle="#0a0f18";g.beginPath();g.ellipse(bx,by2+26,4.5,2.6,0,0,7);g.fill();
    g.strokeStyle="rgba(150,166,196,"+(offl?0.08:0.2)+")";g.lineWidth=0.9;
    g.beginPath();g.ellipse(bx,by2+26,4.5,2.6,0,0,7);g.stroke();
  });

  /* ---- 2 · siege arms: piston, hammer gauntlet, stud knuckles ----
     Working, the RIGHT arm flexes — elbow out, fist raised over the bench,
     the way claude carries a working arm. That side is drawn LATE (after the
     waist, via drawWorkArm) so the raised forearm reads in front of the
     torso; anything drawn here first would be overpainted by the chest
     plates — the same trap codex's front legs taught. */
  var handR=null;
  function drawArm(sg){
    /* The flex lives on the LEFT arm: the right side of every bench carries
       a desk screen (builder's sign monitor, reviewer's readout) exactly
       where a flexed right fist lands its arc — the torch was burning
       behind glass. The left half of the bench is the open work area (the
       builder's rig lives there), so the tally fist is the working fist. */
    var flex=(sg<0&&work);
    var shx=cx+sg*108,shy=BY-30,
        elx=cx+sg*(flex?144:134),ely=flex?BY+22:BY+30,
        gxx=cx+sg*(flex?106:128),gyy=flex?BY+82:BY+96;
    // shoulder ball in its socket
    g.fillStyle="#04070c";g.beginPath();g.arc(shx,shy,13,0,7);g.fill();
    plate(g,[[shx-10,shy-14],[shx+10,shy-14],[shx+8,shy+2],[shx-8,shy+2]],sM,sB,ed);
    bolt(g,shx-5,shy-7,2,offl?0.06:0.2);bolt(g,shx+5,shy-7,2,offl?0.06:0.2);
    var sg2=g.createRadialGradient(shx-4,shy-5,2,shx,shy,13);
    sg2.addColorStop(0,"rgba(196,208,232,"+(offl?0.14:0.32)+")");sg2.addColorStop(1,"rgba(4,8,14,0.8)");
    g.fillStyle=sg2;g.beginPath();g.arc(shx,shy,8.6,0,7);g.fill();
    // upper arm: thick armour + the piston along its underside
    seg2(g,shx,shy+4,elx,ely,18,14,sT,sB,ed);
    pl(g,shx+sg*2,shy+10,elx+sg*2,ely-4,"rgba(6,9,15,0.9)",4);
    pl(g,shx+sg*2,shy+10,elx+sg*2,ely-4,"rgba(150,164,190,"+(offl?0.08:0.24)+")",1.4);
    // elbow: dark ball, lit crescent
    g.fillStyle="#04070c";g.beginPath();g.arc(elx,ely,10,0,7);g.fill();
    g.strokeStyle="rgba(150,164,190,"+(offl?0.08:0.26)+")";g.lineWidth=1.6;
    g.beginPath();g.arc(elx,ely,7,-2.4,0.6);g.stroke();
    bolt(g,elx,ely,2.6,offl?0.06:0.2);
    // the GAUNTLET: a hammer block, knuckle studs, scuffed to metal.
    // Thick-limb rule: the forearm is armour you could not close a hand
    // around, and the fist is the widest thing below the pauldron line.
    seg2(g,elx,ely+2,gxx,gyy-30,18,21,sM,sB,ed);
    // wrist clamp where the forearm meets the hammer
    (function(){var wx=(elx+gxx)/2,wy=(ely+gyy-28)/2+6;
      seg2(g,wx-sg*2,wy-7,wx+sg*2,wy+7,22,22,sM,sB,ed);
      bolt(g,wx-sg*10,wy,2.2,offl?0.06:0.2);bolt(g,wx+sg*8,wy+2,2.2,offl?0.06:0.2);})();
    var gw=58,gh=66;
    plate(g,[[gxx-gw/2,gyy-28],[gxx+gw/2,gyy-28],[gxx+gw/2-6,gyy+gh-28],[gxx-gw/2+2,gyy+gh-28]],sT,sB,ed);
    cavity(g,gxx-gw/2,gyy-28,gw,9,0.5);
    pl(g,gxx-gw/2+3,gyy+gh-30,gxx+gw/2-3,gyy+gh-30,"rgba(3,6,11,0.6)",2);        // knuckle line
    for(var fg=1;fg<4;fg++){pl(g,gxx-gw/2+fg*(gw/4),gyy+gh-30,gxx-gw/2+fg*(gw/4)-1,gyy+gh-34,"rgba(3,6,11,0.5)",1.6);}
    for(var ks=0;ks<4;ks++){bolt(g,gxx-gw/2+8+ks*((gw-16)/3),gyy+gh-34,3.4,offl?0.06:0.26);}
    // the striking band: paint worn to bare metal across the whole bottom face
    g.fillStyle="rgba(198,214,240,"+(offl?0.05:0.12)+")";
    g.fillRect(gxx-gw/2+3,gyy+gh-30.5,gw-9,3);
    /* kill tallies on the LEFT fist — counted where they were made. Worn
       gold, four and a strike-through, the paint half gone. */
    if(sg<0){g.strokeStyle="rgba(212,178,110,"+(offl?0.14:0.38)+")";g.lineWidth=1.3;
      for(var tl=0;tl<4;tl++){g.beginPath();g.moveTo(gxx-14+tl*7,gyy-8);g.lineTo(gxx-15+tl*7,gyy+6);g.stroke();}
      g.beginPath();g.moveTo(gxx-18,gyy+3);g.lineTo(gxx+9,gyy-5);g.stroke();
      g.strokeStyle="rgba(212,178,110,"+(offl?0.05:0.13)+")";
      g.beginPath();g.moveTo(gxx-14+7,gyy-8);g.lineTo(gxx-15+7,gyy+6);g.stroke();}
    pl(g,gxx-gw/2+4,gyy+gh-28.6,gxx+gw/2-8,gyy+gh-28.6,"rgba(198,216,246,"+(offl?0.08:0.2)+")",1.2); // fist bottom catch
    /* the torch is below and inboard: the fist's bottom face and its inner
       edge catch pink — the strongest of the underlight cues because the
       fists hang closest to the fire */
    if(!offl){pl(g,gxx-gw/2+4,gyy+gh-27,gxx+gw/2-8,gyy+gh-27,pkh(0.34*th),1.6);
      var ie=gxx-sg*(gw/2-4);
      pl(g,ie,gyy-22,ie-sg*3,gyy+gh-31,pk(0.22*th),1.4);}
    g.fillStyle="rgba(206,220,242,"+(offl?0.08:0.22)+")";                          // scuffed striking face
    g.fillRect(gxx-gw/2+5,gyy+gh-29.6,10,1.6);g.fillRect(gxx+4,gyy-26,8,1.6);
    // hydraulic hose: pauldron to gauntlet — one thick line, not spaghetti.
    // Dead the pressure is gone and the line hangs slack; flexed it pulls taut.
    hose(g,shx-sg*9,shy+2,gxx-sg*18,gyy-22,flex?11:(offl?31:22),5.2);
    if(flex)handR={x:gxx-sg*12,y:gyy+36};
    /* The torch TOOL — builder only; the other rooms put their own device
       in the working hand. A stubby gripped barrel exiting the fist's
       inner-bottom corner, clamped where it leaves the knuckles, hot ring
       at the tip: the arc now comes off a tool, not off bare studs. Stubby
       on purpose — a wand would be the thinnest thing on the unit, and the
       only thin thing allowed is the broken one. */
    if(flex&&ROOM==="builder"){
      seg2(g,gxx-sg*20,gyy+20,gxx-sg*40,gyy+33,4.6,3.2,"#1c2432","#0a0e16","#2d3749");
      seg2(g,gxx-sg*25,gyy+22,gxx-sg*28,gyy+26,6,6,sM,sB,ed);
      g.fillStyle="#05080e";g.beginPath();g.arc(gxx-sg*40,gyy+33,2.7,0,7);g.fill();
      g.strokeStyle="rgba(200,216,244,"+(offl?0.1:0.3)+")";g.lineWidth=1;
      g.beginPath();g.arc(gxx-sg*40,gyy+33,2.7,3.6,5.9);g.stroke();
      [RB,RE].forEach(function(c){c.fillStyle="rgba(255,246,252,0.9)";
        c.beginPath();c.arc(gxx-sg*41,gyy+35,1.3,0,7);c.fill();});
      handR={x:gxx-sg*42,y:gyy+36};
    }
    else if(sg>0&&!work)handR={x:gxx+10,y:gyy+12};
  }
  drawArm(1);
  if(!work)drawArm(-1);          // the flexed left arm waits for the torso

  /* ---- 2b · intake scoops, behind everything ----
     Two ram-air ducts rise between the head and the cowls — a nuclear torch
     still breathes coolant. Drawn before the chest so only their throats
     clear the trapezius line; the mouths are the one new thing on the
     silhouette's crown. */
  [-1,1].forEach(function(sg){
    var ix=cx+sg*78;
    plate(g,[[ix-sg*14,BY-62],[ix-sg*8,BY-90],[ix+sg*4,BY-96],[ix+sg*13,BY-89],[ix+sg*12,BY-62]],sM,sB,ed);
    g.fillStyle="#04070c";g.beginPath();g.ellipse(ix+sg*2,BY-91,8,3.6,sg*0.28,0,7);g.fill();
    g.strokeStyle="rgba(186,204,238,"+(offl?0.07:0.18)+")";g.lineWidth=1.1;
    g.beginPath();g.ellipse(ix+sg*2,BY-91,8,3.6,sg*0.28,3.4,6.1);g.stroke();
    pl(g,ix-sg*12,BY-68,ix-sg*7,BY-86,"rgba(4,8,14,0.5)",1.2);});

  /* ---- 3 · CHEST: the bunker ---- */
  // under-torso shadow plate
  plate(g,[[cx-88,BY+20],[cx+88,BY+20],[cx+64,BY+66],[cx-64,BY+66]],sM,"#05080d",ed);
  if(!offl)pl(g,cx-63,BY+65,cx+63,BY+65,pkh(0.22*th),1.5);   // its lower arris faces the fire
  // main glacis — one huge slab, faceted
  plate(g,[[cx-96,BY-62],[cx+96,BY-62],[cx+84,BY+30],[cx-84,BY+30]],sT,sB,ed);
  pl(g,cx,BY-62,cx,BY+30,"rgba(4,8,14,0.55)",1.6);                               // centre arris
  pl(g,cx-96,BY-62,cx-34,BY-40,"rgba(4,8,14,0.4)",1.3);                          // facet seams
  pl(g,cx+96,BY-62,cx+34,BY-40,"rgba(4,8,14,0.4)",1.3);
  pl(g,cx-95,BY-61,cx+95,BY-61,"rgba(186,208,242,"+(offl?0.06:0.18)+")",1.4);    // crown catch
  /* Crane lugs on the crown — nothing this heavy walks onto a transport.
     Two bolted D-rings, worn bright where the shackles ride. */
  [-1,1].forEach(function(sg){var lx2=cx+sg*58;
    plate(g,[[lx2-7,BY-60],[lx2+7,BY-60],[lx2+5,BY-54],[lx2-5,BY-54]],sT,sB,ed);
    bolt(g,lx2-3.5,BY-57,1.6,offl?0.05:0.2);bolt(g,lx2+3.5,BY-57,1.6,offl?0.05:0.2);
    g.strokeStyle="#05080e";g.lineWidth=3;g.beginPath();g.arc(lx2,BY-60,4.6,Math.PI,0,false);g.stroke();
    g.strokeStyle="rgba(200,216,244,"+(offl?0.10:0.30)+")";g.lineWidth=1.2;
    g.beginPath();g.arc(lx2,BY-60,4.6,Math.PI+0.3,-0.3,false);g.stroke();});
  cavity(g,cx-84,BY+24,168,10,0.55);                                             // the glacis throws a hard line
  // plastron over the lower chest — bolted, KM-09X stencilled
  plate(g,[[cx-58,BY+6],[cx+58,BY+6],[cx+50,BY+34],[cx-50,BY+34]],sM,sB,ed);
  bolt(g,cx-50,BY+12,2.4,offl?0.06:0.22);bolt(g,cx+50,BY+12,2.4,offl?0.06:0.22);
  g.fillStyle="rgba(198,208,224,"+(offl?0.12:0.3)+")";
  g.font="700 10px ui-monospace,monospace";g.textAlign="center";
  g.fillText("KM-09X",cx,BY+28);g.textAlign="left";
  /* the REACTOR: octagonal caged furnace, the one light that matters.
     Two heavy bars in front of the fire; bloom leaks around, never through. */
  var rc2={x:cx,y:BY-16};
  var pts=[];for(var o=0;o<8;o++){var a=Math.PI/8+o*Math.PI/4;pts.push([rc2.x+Math.cos(a)*33,rc2.y+Math.sin(a)*33]);}
  g.fillStyle="#04070c";poly(g,pts);g.fill();g.strokeStyle=ed;g.lineWidth=1.4;g.stroke();
  var fw={x:rc2.x-19,y:rc2.y-16,w:38,h:32};
  rr(g,fw.x,fw.y,fw.w,fw.h,4);g.fillStyle="#05090f";g.fill();g.strokeStyle=rc;g.lineWidth=1;g.stroke();
  if(!offl){
    /* The furnace is a FIRE, not a lamp: a hard white core that hits the
       bars, falling fast to the vendor pink. The dark window frame between
       core and glacis is what keeps the blaze from washing the armour. */
    g.fillStyle="#080304";g.fillRect(fw.x+1,fw.y+1,fw.w-2,fw.h-2);
    var fire=g.createRadialGradient(rc2.x,rc2.y+2,1,rc2.x,rc2.y+2,17);
    fire.addColorStop(0,"rgba(255,246,252,"+(0.95*pulse+0.05)+")");
    fire.addColorStop(0.32,pkh(0.8*pulse+0.1));fire.addColorStop(0.7,pk(0.4*pulse));fire.addColorStop(1,pk(0.06));
    g.fillStyle=fire;g.fillRect(fw.x+1,fw.y+1,fw.w-2,fw.h-2);
    RE.save();RE.beginPath();rr(RE,fw.x,fw.y,fw.w,fw.h,4);RE.clip();
    var f2=RE.createRadialGradient(rc2.x,rc2.y+2,1,rc2.x,rc2.y+2,20);
    f2.addColorStop(0,"rgba(255,240,250,0.9)");f2.addColorStop(0.5,pk(0.55));f2.addColorStop(1,pk(0));
    RE.fillStyle=f2;RE.fillRect(fw.x,fw.y,fw.w,fw.h);RE.restore();
    // the furnace lights the chest it is set into — tight, so the glacis
    // stays dark armour with a fire in it rather than pink armour
    g.save();g.globalCompositeOperation="lighter";
    var ch=g.createRadialGradient(rc2.x,rc2.y,8,rc2.x,rc2.y,54);
    ch.addColorStop(0,pk(0.13));ch.addColorStop(0.5,pk(0.045));ch.addColorStop(1,pk(0));
    g.fillStyle=ch;g.beginPath();g.arc(rc2.x,rc2.y,54,0,7);g.fill();g.restore();
  }else{
    /* the dead furnace keeps one residual line behind the bars — powered
       enough to be wrong, the fleet's SILENT idiom — and below it, an ember.
       A nuclear core does not go black when the unit dies; it goes DARK RED
       and stays that way for days. Heat, not power: albedo only, no
       emissive, no pulse. */
    RB.fillStyle="rgba(150,168,190,0.3)";RB.fillRect(fw.x+4,rc2.y,fw.w-8,1.5);
    var emb=RB.createRadialGradient(rc2.x,rc2.y+9,0.5,rc2.x,rc2.y+9,11);
    emb.addColorStop(0,"rgba(255,72,44,0.16)");emb.addColorStop(0.6,"rgba(180,40,26,0.08)");
    emb.addColorStop(1,"rgba(120,26,18,0)");
    RB.fillStyle=emb;RB.fillRect(fw.x+1,fw.y+1,fw.w-2,fw.h-2);
  }
  [RB,RE].forEach(function(c,ci){if(ci===1&&offl)return;
    c.fillStyle=ci?"rgba(5,8,13,0.94)":"#0d121c";
    c.fillRect(rc2.x-3,fw.y-2,6,fw.h+4);
    c.fillRect(fw.x-2,rc2.y-2.2,fw.w+4,4.4);});
  bolt(g,rc2.x,fw.y-6,2.4,offl?0.06:0.24);bolt(g,rc2.x,fw.y+fw.h+6,2.4,offl?0.06:0.24);
  // reactor mount bolts on the glacis
  [[-1,-1],[1,-1],[-1,1],[1,1]].forEach(function(sg){bolt(g,rc2.x+sg[0]*36,rc2.y+sg[1]*34,2.6,offl?0.06:0.24);});

  /* ---- 4 · pauldrons: layered cowls over the bells ----
     A veteran's plates never match. The LEFT cowl is the forged original —
     shaped, crowned, and carrying the gouge that should have killed the unit.
     The RIGHT one was lost with the eye: what hangs there now is a field
     replacement — straight mill cuts, a proud weld bead, bolts driven wherever
     they bit, the 09 re-stencilled crooked by whoever fitted it. */
  [-1,1].forEach(function(sg){
    var px=cx+sg*118,py=BY-56;
    if(sg<0){
      // forged original — the biggest single plate on the unit
      plate(g,[[px-sg*56,py+6],[px-sg*30,py-22],[px+sg*34,py-26],[px+sg*52,py-6],[px+sg*44,py+22],[px-sg*40,py+26]],sT,sB,ed);
      pl(g,px-sg*30,py-22,px+sg*34,py-26,"rgba(186,208,242,"+(offl?0.07:0.2)+")",1.5); // crown catch
    }else{
      // field replacement — straight cuts, one chamfer, mill-scale a shade off
      plate(g,[[px-56,py+8],[px-32,py-20],[px+30,py-24],[px+50,py-12],[px+50,py+18],[px-40,py+26]],offl?"#161b24":"#202a38",sB,ed);
      // the weld bead where the new plate was let into the old shoulder
      pl(g,px-32,py-20,px-52,py+4,"rgba(9,13,20,0.9)",3);
      pl(g,px-32,py-20,px-52,py+4,"rgba(186,204,236,"+(offl?0.07:0.2)+")",1.1);
      for(var wd=0;wd<4;wd++){pl(g,px-34-wd*5,py-17+wd*6,px-31-wd*5,py-15+wd*6,"rgba(150,168,196,"+(offl?0.05:0.13)+")",1);}
      // bolts driven wherever they bit
      bolt(g,px-24,py-12,2.6,offl?0.06:0.22);bolt(g,px+14,py-16,2.2,offl?0.06:0.2);
      bolt(g,px+40,py+2,2.6,offl?0.06:0.22);bolt(g,px-6,py+18,2.2,offl?0.06:0.18);
    }
    /* Louvres punched through the cowl face — these plates are ENGINE cowls
       and an engine breathes. Powered, the bell's glow leaks up through the
       slats; the leak is the only light the pauldron armour is allowed.
       The forged left cowl carries its three factory louvres; the field
       plate never got them — the crew cut two crude slots outboard of the
       stencil and called it ventilated. */
    var LVS=sg<0?[[6,8],[-10,11],[-26,14]]:[[16,10],[34,13]];
    LVS.forEach(function(lvd){
      var lx=px+lvd[0], lyv=py+lvd[1];
      var crude=sg>0;
      plate(g,[[lx-9,lyv],[lx+9,lyv-(crude?1:2)],[lx+(crude?8:10),lyv+3],[lx-8,lyv+(crude?4:5)]],"#0a0e16","#05080d","rgba(56,66,88,0.8)");
      if(!crude)pl(g,lx-8,lyv+4.4,lx+9,lyv+2.6,"rgba(186,204,238,"+(offl?0.05:0.14)+")",1);
      if(!offl){RB.fillStyle=pk(0.16+0.12*pulse);RB.fillRect(lx-6,lyv+0.5,12,2.2);
        RE.fillStyle=pk(0.28+0.14*pulse);RE.fillRect(lx-6,lyv+0.5,12,2.2);}});
    // lower rim plate
    plate(g,[[px-sg*48,py+28],[px+sg*44,py+24],[px+sg*38,py+42],[px-sg*42,py+44]],sM,sB,ed);
    cavity(g,px-sg*44,py+24,86,6,0.5);
    // rim bolts + grime weep (albedo)
    // grime weep on the ORIGINAL side only — a plate fitted last refit has
    // not had time to stain (subtraction round, L11)
    [px-sg*40,px-sg*8,px+sg*28].forEach(function(bxp,i){
      bolt(g,bxp,py+33,2.4,offl?0.06:0.22);
      if(i===1&&sg<0){g.fillStyle="rgba(70,50,30,0.3)";poly(g,[[bxp-1.2,py+35],[bxp+1.2,py+35],[bxp+0.5,py+42],[bxp-0.5,py+42]]);g.fill();}});
  });
  // the GOUGE across the left pauldron — torn lip catches the lamp
  poly(g,[[cx-164,BY-66],[cx-128,BY-50],[cx-133,BY-42],[cx-168,BY-58]]);g.fillStyle="rgba(2,4,8,1)";g.fill();
  pl(g,cx-164,BY-66,cx-128,BY-50,"rgba(198,216,246,"+(offl?0.1:0.36)+")",1.6);
  // "09" re-stencilled on the replacement plate, crooked and part-dry
  g.save();g.globalAlpha=offl?0.14:0.34;g.fillStyle="#c6d2e4";
  g.translate(cx+118,BY-42);g.rotate(-0.06);
  g.font="700 17px ui-monospace,monospace";g.textAlign="center";
  g.fillText("09",0,0);g.restore();g.textAlign="left";
  /* Chipped edges — only at the pauldron tips. The glacis-corner pair from
     the prototype died in the port: those corners sit UNDER the cowls here,
     so the nicks were landing on top of the pauldron paint as floating
     specks (subtraction round, L11). */
  g.fillStyle="rgba(206,220,242,"+(offl?0.09:0.24)+")";
  [[cx-172,BY-50],[cx+170,BY-48]].forEach(function(nk,i){g.fillRect(nk[0],nk[1],3+(i%2),1.6);});
  /* ---- 4b · the battles ----
     A bite out of the left pauldron's lower rim, cut to TRANSPARENCY — a hit
     that removed metal, not paint. The room shows through and the rim light
     catches the tear on its own, because the silhouette itself changed. */
  RB.save();RB.globalCompositeOperation="destination-out";
  poly(RB,[[cx-168,BY-38],[cx-144,BY-29],[cx-155,BY-17],[cx-170,BY-24]]);RB.fill();RB.restore();
  pl(g,cx-168,BY-38,cx-155,BY-17,"rgba(198,216,246,"+(offl?0.1:0.3)+")",1.3);
  /* A crack across the left glacis facet, strapped rather than repaired —
     somebody bolted two straps over it mid-campaign and the unit kept flying. */
  g.strokeStyle="rgba(4,7,12,0.85)";g.lineWidth=1.6;
  g.beginPath();g.moveTo(cx-74,BY-44);g.lineTo(cx-60,BY-32);g.lineTo(cx-63,BY-24);g.lineTo(cx-48,BY-10);g.stroke();
  g.strokeStyle="rgba(178,196,226,"+(offl?0.05:0.12)+")";g.lineWidth=0.8;
  g.beginPath();g.moveTo(cx-73,BY-43);g.lineTo(cx-59,BY-31);g.stroke();
  [[cx-70,BY-40,cx-56,BY-36],[cx-60,BY-20,cx-46,BY-16]].forEach(function(sp){
    plate(g,[[sp[0],sp[1]-3],[sp[2],sp[3]-3],[sp[2],sp[3]+3],[sp[0],sp[1]+3]],sT,sB,ed);
    bolt(g,sp[0]+2,sp[1],1.7,offl?0.05:0.2);bolt(g,sp[2]-2,sp[3],1.7,offl?0.05:0.2);});
  /* Scorch climbing from the furnace's lower lip — one overpressure, long
     ago; soot outlasts paint (albedo only, never emissive). */
  var sc2=g.createLinearGradient(0,BY+4,0,BY+34);
  sc2.addColorStop(0,"rgba(10,6,4,0.45)");sc2.addColorStop(1,"rgba(10,6,4,0)");
  g.save();g.translate(cx-30,0);g.rotate(-0.05);
  g.fillStyle=sc2;g.beginPath();g.moveTo(-8,BY+4);g.quadraticCurveTo(-16,BY+22,-10,BY+34);g.lineTo(4,BY+34);g.quadraticCurveTo(-2,BY+18,2,BY+4);g.closePath();g.fill();g.restore();

  /* ---- 5 · HEAD: buried, no neck, brow like a firing slit ----
     Offline it sinks 6px deeper between the cowls — a head with no neck
     cannot hang, so "head down" is the whole skull settling into the chest. */
  var hy=BY-(offl?52:58);
  plate(g,[[cx-44,hy+6],[cx-50,hy-18],[cx-33,hy-30],[cx+33,hy-30],[cx+50,hy-18],[cx+44,hy+6]],sT,sB,ed);
  /* The crown is recessed, not a lit lid — the head must read buried between
     the cowls, and a bright top face floated it up off the shoulders. */
  cavity(g,cx-33,hy-30,66,6,0.4);
  pl(g,cx,hy-30,cx,hy-6,"rgba(4,8,14,0.55)",1.4);
  // the brow — two plates dipped toward the centre, so the unit SCOWLS
  plate(g,[[cx-42,hy-27],[cx+2,hy-24],[cx-2,hy-10],[cx-36,hy-12]],sM,sB,ed);
  plate(g,[[cx+42,hy-27],[cx-2,hy-24],[cx+2,hy-10],[cx+36,hy-12]],sM,sB,ed);
  cavity(g,cx-36,hy-12,72,7,0.6);
  bolt(g,cx-38,hy-20,2,offl?0.05:0.18);bolt(g,cx+38,hy-20,2,offl?0.05:0.18);
  var vs={x:cx-32,y:hy-12,w:64,h:10};
  rr(g,vs.x,vs.y,vs.w,vs.h,3);g.fillStyle="#03060b";g.fill();g.strokeStyle=rc;g.lineWidth=1;g.stroke();
  if(offl){
    /* collapse line — kimi's own idiom from its screen days, kept in the
       visor: one bright line says the panel is powered enough to be wrong */
    RB.fillStyle="rgba(150,168,190,0.5)";RB.fillRect(vs.x+4,vs.y+4.4,vs.w-8,1.4);
    RE.fillStyle="rgba(150,168,190,0.2)";RE.fillRect(vs.x+4,vs.y+4.4,vs.w-8,1.4);}
  else{
    /* The threat-scan lives in the PINK optic only. The amber eye is the
       replacement — it glows, but it is set in the socket and does not
       gimbal; the mismatch between a sweeping eye and a fixed one is what
       makes the idle scan read as damage rather than animation. */
    /* The slit itself is a live instrument: a cold strip of light runs its
       floor so the visor reads as a sensor bar at room scale, not a dark
       groove with two dots in it. */
    var sg3=g.createLinearGradient(0,vs.y+6.5,0,vs.y+9.5);
    sg3.addColorStop(0,pk(0.16*(0.6+0.4*pulse)));sg3.addColorStop(1,pk(0));
    g.fillStyle=sg3;g.fillRect(vs.x+3,vs.y+6.5,vs.w-6,3);
    var gaze=(work||reduced)?0:Math.round(Math.sin(t*0.55)*5);
    [{x:cx-15,col:AM,colH:AMH},{x:cx+15+gaze,col:PK,colH:PKH}].forEach(function(op,oi){ // amber glass eye + pink
      [RB,RE].forEach(function(c){var eg=c.createRadialGradient(op.x,vs.y+5,0.4,op.x,vs.y+5,7.5);
        eg.addColorStop(0,"rgba("+op.colH[0]+","+op.colH[1]+","+op.colH[2]+","+(0.85+0.15*pulse)+")");
        eg.addColorStop(0.5,"rgba("+op.col[0]+","+op.col[1]+","+op.col[2]+","+(0.5*pulse)+")");
        eg.addColorStop(1,"rgba("+op.col[0]+","+op.col[1]+","+op.col[2]+",0)");
        c.fillStyle=eg;c.beginPath();c.arc(op.x,vs.y+5,7.5,0,7);c.fill();});
      // hard lens in a bezel, not a dot
      g.strokeStyle="rgba(3,6,11,0.9)";g.lineWidth=1.2;
      rr(g,op.x-3.6,vs.y+1.6,7.2,7.2,2);g.stroke();
      [RB,RE].forEach(function(c){c.fillStyle="rgba("+op.colH[0]+","+op.colH[1]+","+op.colH[2]+",0.95)";
        rr(c,op.x-3,vs.y+2.2,6,6,1.8);c.fill();});
      if(oi===0){ // the glass eye reflects the lamp above — a fixed catchlight
        RB.fillStyle="rgba(255,255,255,0.75)";RB.fillRect(op.x-1.8,vs.y+3,1.4,1.4);}
      else if(work){ // ranging hairline through the live optic: aiming, not looking
        [RB,RE].forEach(function(c){c.fillStyle="rgba(255,240,250,0.5)";
          c.fillRect(op.x-0.5,vs.y+0.8,1,8.6);});}});
  }
  // the crack that cost the eye
  g.strokeStyle="rgba(190,205,228,"+(offl?0.08:0.26)+")";g.lineWidth=0.9;
  g.beginPath();g.moveTo(vs.x+9,vs.y+0.6);g.lineTo(vs.x+16,vs.y+5);g.lineTo(vs.x+13,vs.y+9);g.stroke();
  /* Cheekbones — the anatomy that made claude read like a fighter: one hard
     lit plane each side at eye level, angling down and in under the visor.
     On a slit-visor head they are the armour's zygomatic wedges. */
  [-1,1].forEach(function(sg){
    plate(g,[[cx+sg*44,hy-4],[cx+sg*18,hy+0.5],[cx+sg*24,hy+6],[cx+sg*42,hy+2]],sM,sB,ed);
    pl(g,cx+sg*44,hy-4,cx+sg*18,hy+0.5,"rgba(198,216,246,"+(offl?0.08:0.28)+")",1.4);});
  /* The jaw: a squared chin plate dropping onto the glacis crown, so the head
     grows out of the chest instead of hovering over it — the no-neck read is
     a fighter's, only if the two masses actually meet. */
  plate(g,[[cx-30,hy+4],[cx+30,hy+4],[cx+22,hy+15],[cx-22,hy+15]],sM,sB,ed);
  cavity(g,cx-22,hy+9,44,6,0.45);
  // armoured sensor ears — short, armoured, no whips
  [-1,1].forEach(function(sg){plate(g,[[cx+sg*44,hy-22],[cx+sg*54,hy-19],[cx+sg*54,hy-7],[cx+sg*44,hy-8]],sM,sB,ed);
    pl(g,cx+sg*44,hy-22,cx+sg*54,hy-19,"rgba(186,208,242,"+(offl?0.06:0.16)+")",1.2);
    if(!offl){RE.fillStyle=pk(0.5);RE.beginPath();RE.arc(cx+sg*49,hy-14,1.6,0,7);RE.fill();}});
  /* The rangefinder mast, and the bend it took. A short armoured stub off
     the crown's right shoulder, kinked 20 degrees at the joint by a hit that
     was never worth straightening — the instrument still works, so it stays
     bent. The one thin thing on the unit, and it is thin because it is
     broken. */
  (function(){var mx=cx+24,m0=hy-29,m1=hy-38,tx2=cx+20,ty2=hy-45;
    plate(g,[[mx-3.5,m0],[mx+3.5,m0],[mx+2.5,m0-4],[mx-2.5,m0-4]],sM,sB,ed);
    pl(g,mx,m0-3,mx,m1,"rgba(16,21,30,0.98)",3);
    pl(g,mx-0.8,m0-3,mx-0.8,m1,"rgba(160,176,204,"+(offl?0.08:0.2)+")",0.9);
    pl(g,mx,m1,tx2,ty2,"rgba(16,21,30,0.98)",2.4);
    bolt(g,mx,m1,1.8,offl?0.05:0.16);
    g.fillStyle="#0a0f18";g.beginPath();g.arc(tx2,ty2,2.4,0,7);g.fill();
    if(!offl){RB.fillStyle=pkh(0.5+0.3*pulse);RB.beginPath();RB.arc(tx2,ty2,1.1,0,7);RB.fill();
      RE.fillStyle=pk(0.6);RE.beginPath();RE.arc(tx2,ty2,1.1,0,7);RE.fill();}})();

  /* ---- 6 · waist cincture + nozzle cowl ---- */
  // overlapping armoured leaves, like scale mail — layered, not extruded
  /* The middle leaf is GONE: in its place, the abdomen's service band — the
     recess the crew stopped re-armouring. Twin hydraulic rams, a ribbed
     bellows spine, and the cable run, all in a cavity the furnace glow
     reaches from above. The unit's waist is a machine, not a skirt. */
  (function(){var by2=BY+58;
    plate(g,[[cx-50,by2],[cx+50,by2],[cx+54,by2+22],[cx-54,by2+22]],"#0a0e15","#04070b","#1d2530");
    if(!offl){var ag=g.createLinearGradient(0,by2,0,by2+22);
      ag.addColorStop(0,pk(0.12));ag.addColorStop(1,pk(0.02));
      g.fillStyle=ag;g.fillRect(cx-50,by2,100,22);}
    // ribbed bellows spine, centre
    for(var rb2=0;rb2<5;rb2++){pl(g,cx-9,by2+3+rb2*4,cx+9,by2+3+rb2*4,"rgba(4,7,12,0.9)",2.2);
      pl(g,cx-9,by2+2+rb2*4,cx+9,by2+2+rb2*4,"rgba(150,166,194,"+(offl?0.06:0.14)+")",0.8);}
    // twin rams: dark cylinder, bright rod under load — the rods breathe
    // against the hover bob, counter-phased, because they are what carries
    // the waist. Dead or reduced they sit at half stroke.
    [-1,1].forEach(function(rs){var rx2=cx+rs*30;
      var ext=(offl||reduced)?1.5:1.5+Math.sin(t*1.6+(rs>0?Math.PI:0))*1.4;
      plate(g,[[rx2-6,by2+2],[rx2+6,by2+2],[rx2+6,by2+12],[rx2-6,by2+12]],sM,sB,ed);
      pl(g,rx2,by2+12,rx2,by2+19.5+ext,"rgba(8,12,18,0.95)",5);
      pl(g,rx2,by2+12,rx2,by2+19.5+ext,"rgba(196,212,240,"+(offl?0.10:0.30)+")",1.6);});
    // corner grommet bolts
    bolt(g,cx-46,by2+4,2,offl?0.05:0.18);bolt(g,cx+46,by2+4,2,offl?0.05:0.18);
    bolt(g,cx-48,by2+18,2,offl?0.05:0.18);bolt(g,cx+48,by2+18,2,offl?0.05:0.18);
    if(!offl)pl(g,cx-52,by2+21.2,cx+52,by2+21.2,pkh(0.21*th),1.4);})();
  for(var lf=0;lf<3;lf++){
    if(lf===1)continue;
    var lw=58-lf*12, ly=BY+36+lf*22;
    plate(g,[[cx-lw,ly],[cx+lw,ly],[cx+lw+8,ly+20],[cx+6,ly+20],[cx,ly+15],[cx-6,ly+20],[cx-lw-8,ly+20]],lf%2?sM:sT,sB,ed);
    cavity(g,cx-lw-8,ly+13,(lw+8)*2,6,0.5);
    /* each leaf's lower edge catches the torch, stronger the lower the leaf
       hangs — the underlight climbing the scale armour is what says the fire
       is real when the flame itself sits behind the near-plane bench */
    if(!offl){var la=(0.12+lf*0.09)*th;
      pl(g,cx-lw-7,ly+19.2,cx-7,ly+19.2,pkh(la),1.4);pl(g,cx+7,ly+19.2,cx+lw+7,ly+19.2,pkh(la),1.4);}}
  /* Naked wires — the rough-service read that costs no clutter: a three-line
     loom ducking out of the waist stack through grommets and back in two
     leaves down, and one clamped feed line running the cowl flank to the
     nozzle. Service crews do not hide cable on a machine they open weekly. */
  [0,1].forEach(function(wq){
    hose(g,cx-44+wq*4,BY+57+wq*3,cx-10+wq*3,BY+79+wq*2,9-wq*3,2.4);});
  g.fillStyle="#05080e";
  g.beginPath();g.arc(cx-44,BY+58,3.4,0,7);g.fill();g.beginPath();g.arc(cx-8,BY+80,3.4,0,7);g.fill();
  g.fillStyle="rgba(190,206,232,"+(offl?0.05:0.14)+")";
  g.fillRect(cx-46,BY+55,4,1.4);g.fillRect(cx-10,BY+77,4,1.4);
  // the cowl: a heavy armoured cone with vector vanes
  plate(g,[[cx-46,BY+102],[cx+46,BY+102],[cx+24,nozY-4],[cx-24,nozY-4]],sM,sB,ed);
  /* Jet-blast warning band around the cowl throat — engines carry hazard
     stripes, and this one has carried them through every campaign: two ticks
     scoured off entirely, the rest half-scorched. Albedo only, never lit. */
  for(var hz=0;hz<10;hz++){
    if(hz===2||hz===7)continue;
    var hx0=cx-44+hz*8.8, ha=(hz%3===1?0.5:0.3)*(offl?0.45:1);
    g.fillStyle=hz%2?"rgba(188,152,72,"+(ha*0.66)+")":"rgba(20,16,10,"+ha+")";
    poly(g,[[hx0,BY+104],[hx0+6.6,BY+104],[hx0+4.4,BY+109],[hx0-2.2,BY+109]]);g.fill();}
  pl(g,cx-38,BY+106,cx-26,nozY-10,"rgba(10,14,21,0.95)",2.6);       // clamped feed line
  pl(g,cx-38,BY+106,cx-26,nozY-10,"rgba(130,144,170,"+(offl?0.06:0.16)+")",0.9);
  // clamps ride the line by fraction, so they tuck with the bell when it parks
  [0.35,0.75].forEach(function(cf){
    var clx=cx-38+cf*12, cly=BY+106+cf*(nozY-116-BY);
    plate(g,[[clx-3,cly-2],[clx+3,cly-2],[clx+3,cly+2],[clx-3,cly+2]],sT,sB,ed);});
  [-1,1].forEach(function(vn){
    plate(g,[[cx+vn*30-5,BY+118],[cx+vn*30+5,BY+118],[cx+vn*26+3,nozY-6],[cx+vn*26-7,nozY-6]],sT,sB,ed);});
  // nozzle bell
  g.fillStyle="#04070c";g.beginPath();g.ellipse(cx,nozY-2,17,8,0,0,7);g.fill();
  g.strokeStyle=eH;g.lineWidth=1.2;g.beginPath();g.ellipse(cx,nozY-2,17,8,0,0,7);g.stroke();
  if(!offl){RB.fillStyle=pkh(0.5+0.3*pulse);RB.beginPath();RB.ellipse(cx,nozY-2,9,4.4,0,0,7);RB.fill();
    RE.fillStyle=pk(0.6);RE.beginPath();RE.ellipse(cx,nozY-2,9,4.4,0,0,7);RE.fill();}
  // scorch staining up the cowl — the torch marks its own machine (albedo)
  var sco=g.createLinearGradient(0,nozY-30,0,nozY-2);
  sco.addColorStop(0,"rgba(8,5,3,0)");sco.addColorStop(1,"rgba(8,5,3,0.5)");
  g.fillStyle=sco;poly(g,[[cx-30,BY+118],[cx+30,BY+118],[cx+24,nozY-4],[cx-24,nozY-4]]);g.fill();

  // the flexed working arm lands here — over the torso, under the jet's light
  if(work)drawArm(-1);

  /* the jet's underlight: everything above the nozzle catches pink from
     below — the one lighting cue that says the torch is REAL. */
  if(!offl){g.save();g.globalCompositeOperation="lighter";
    var ul=g.createRadialGradient(cx,nozY-10,4,cx,nozY-10,90);
    ul.addColorStop(0,pk(0.14*th));ul.addColorStop(1,pk(0));
    g.fillStyle=ul;g.beginPath();g.arc(cx,nozY-10,90,0,7);g.fill();g.restore();
    [-128,128].forEach(function(dx){g.save();g.globalCompositeOperation="lighter";
      var uf=g.createRadialGradient(cx+dx*0.9,BY+120,2,cx+dx*0.9,BY+120,40);
      uf.addColorStop(0,pk(0.09*th));uf.addColorStop(1,pk(0));
      g.fillStyle=uf;g.beginPath();g.arc(cx+dx*0.9,BY+120,40,0,7);g.fill();g.restore();});}

  /* ---- 7 · offline: the beacon finds the wreck ----
     The knuckle-rest hides most of the unit behind the bench, so the red
     lands on what still shows: the left pauldron arris, the head's left
     edge, the left scoop's mouth rim, and the bent mast — the highest metal
     on the crown catches the most. All breathe with beaconPulse, same as
     the rooms' own offline rims. */
  if(offl){var bp2=0.35+0.65*beaconPulse;
    pl(g,cx-172,BY-50,cx-160,BY-30,"rgba(255,64,52,"+(0.24*bp2)+")",2);
    pl(g,cx-46,hy-18,cx-40,hy+6,"rgba(255,64,52,"+(0.18*bp2)+")",1.6);
    g.strokeStyle="rgba(255,64,52,"+(0.30*bp2)+")";g.lineWidth=1.1;
    g.beginPath();g.ellipse(cx-76,BY-91,8,3.6,-0.28,3.4,5.6);g.stroke();
    pl(g,cx+23.2,hy-32,cx+23.2,hy-38,"rgba(255,64,52,"+(0.30*bp2)+")",1.2);
    pl(g,cx+24,hy-38,cx+20,hy-45,"rgba(255,64,52,"+(0.26*bp2)+")",1.1);
    RE.strokeStyle="rgba(255,64,52,"+(0.12*bp2)+")";RE.lineWidth=2.4;
    RE.beginPath();RE.moveTo(cx-172,BY-50);RE.lineTo(cx-160,BY-30);RE.stroke();
    RE.strokeStyle="rgba(255,64,52,"+(0.10*bp2)+")";RE.lineWidth=1.6;
    RE.beginPath();RE.moveTo(cx+24,hy-30);RE.lineTo(cx+20,hy-45);RE.stroke();}

  RB.setTransform(SS,0,0,SS,0,0);RE.setTransform(SS,0,0,SS,0,0);RR.setTransform(SS,0,0,SS,0,0);
  buildRim(offl?[94,84,90]:[255,114,182]);      // kimi: pink
  /* Powered, the deck feels the torch: one soft pool under the nozzle, lifted
     by the full hover height. Offline the fists ARE the contact — two hard
     patches at the gauntlets, exactly where the knuckles meet the deck. */
  var feet=offl
    ?[{x:TX(cx-128),y:TY(FLOORL),w:F*30},{x:TX(cx+128),y:TY(FLOORL),w:F*30},
      {x:TX(cx),y:TY(FLOORL),w:F*20}]
    :[{x:TX(cx),y:TY(nozY+6),w:F*26}];
  var hh=handR||{x:cx+150,y:BY+108};
  return {hand:{x:TX(hh.x),y:TY(hh.y)},coreY:TY(BY-16),hy:TY(BY-65),offl:offl,work:work,
          feet:feet};
}

/* The top of the unit, measured off the sprite the renderer just built, cached
   per agent and state — twelve scans over the life of the page, once each.
   Everything that puts a mark ABOVE a unit was using `hy` for this, and hy is
   the visor: the point a holo tether leaves from. Those are the same place on
   claude and grok, who wear their heads on top, and they are 93px apart on
   codex, whose body hangs low inside an arch of six legs — and were 62px
   apart on the drone kimi used to be. So the room's offline diamond sat
   among codex's legs instead of over it, in every room, for every state — the
   full-size twin of the misplaced "!" the god-view cell had.
   Measured rather than tabulated because a table of four numbers goes stale the
   first time a robot changes shape, silently, and this cannot. */
var unitTops={};
function unitTop(){
  var k=AGENT+"|"+STATE;
  if(unitTops[k]!==undefined)return unitTops[k];
  var d=RB.getImageData(0,0,RW,RH).data;
  for(var y=0;y<RH;y++)for(var x=0;x<RW;x++)if(d[(y*RW+x)*4+3]>24)return (unitTops[k]=y);
  return (unitTops[k]=0);
}
function drawRobot(t){
  var info=buildRobo(t,STATE);lastHand=info.hand;
  var sc=0.74, px=ROBOX-260*sc, py=FLOORY-560*sc;
  /* The kimi lift special-case is gone with the drone: the JUGGERNAUT draws
     its own altitude — powered it hangs over its torch with the head level
     with claude's, offline it drops until the knuckles meet the deck. */
  /* Publish where this unit landed, once, in room coordinates. buildRobo
     reports the hand, the head and the footprints in its own canvas space and
     drawRobot is what maps that space onto the floor — so anything else that
     wants to mark a unit (the god-view cell's alert glyph, its weld arc) reads
     the result rather than re-deriving it and getting it wrong for two of the
     four vendors. */
  lastFeet=info.feet;
  lastAnchors={sprite:{x:px,y:py,s:sc},
               hand:{x:px+info.hand.x*sc,y:py+info.hand.y*sc},
               head:{x:px+260*sc,y:py+unitTop()*sc},
               feet:(info.feet||[]).map(function(f){return {x:px+f.x*sc,y:py+f.y*sc,w:f.w*sc};})};
  /* Contact shadows, one per footprint the unit reported.
     This used to be a single soft ellipse pinned at ROBOX+54 for every walker
     and ROBOX for every floater. It sat under nothing in particular — 54px to
     the right of claude, nowhere near any of codex's six feet — and it was the
     same blob whether a unit was planted on the deck or hanging 60px off it.
     So nothing in the room read as touching the floor, which is the one job a
     contact shadow has.
     The rule is the physical one: the further a foot is above the surface, the
     wider, softer and fainter its shadow. That single line is what makes
     claude, codex and now grok read as heavy and kimi reads as airborne,
     without any of them being special-cased. */
  /* Offline kimi is NOT floating any more: the torch is dead and the unit
     rests on its own knuckles, so those two contacts get the hard core every
     planted foot gets. Grok is grounded in every state — the stalker rebuild
     took the jetpack with it. */
  var floating=(AGENT==="kimi"&&!info.offl);
  var feet=info.feet||[{x:260,y:560,w:90}];
  S.save();
  feet.forEach(function(f){
    var fx2=px+f.x*sc, fy2=py+f.y*sc, fw=Math.max(6,f.w*sc);
    var lift=Math.max(0,FLOORY-fy2);              // how high off the deck this foot is
    var spread=1+Math.min(2.6,lift/34);           // soft-shadow growth with distance
    var a=(floating?0.44:0.66)/Math.pow(spread,1.25);
    var w2=fw*spread, h2=Math.max(3,fw*0.34*spread);
    var sh=S.createRadialGradient(fx2,FLOORY+6,1,fx2,FLOORY+6,w2);
    sh.addColorStop(0,"rgba("+shadowRGB()+","+a.toFixed(3)+")");
    sh.addColorStop(0.55,"rgba("+shadowRGB()+","+(a*0.45).toFixed(3)+")");
    sh.addColorStop(1,"rgba("+shadowRGB()+",0)");
    S.fillStyle=sh;S.beginPath();S.ellipse(fx2,FLOORY+6,w2,h2,0,0,7);S.fill();
    /* The dark core right at the contact point. Only for a foot that is
       actually down — it is the thing that says "touching", so a hovering
       unit must not get one. */
    if(lift<7&&!floating){S.fillStyle="rgba("+shadowRGB()+",0.5)";S.beginPath();S.ellipse(fx2,FLOORY+4,fw*0.62,Math.max(2,fw*0.2),0,0,7);S.fill();}
  });
  S.restore();
  if(!info.offl&&AGENT!=="claude"){var vc=AGENT==="codex"?"55,212,166":AGENT==="grok"?"176,124,255":"255,114,182",vr=floating?122:150;S.save();S.globalCompositeOperation="lighter";var tgl=S.createRadialGradient(ROBOX,FLOORY,2,ROBOX,FLOORY,vr);tgl.addColorStop(0,"rgba("+vc+",0.14)");tgl.addColorStop(1,"rgba("+vc+",0)");S.fillStyle=tgl;S.beginPath();S.ellipse(ROBOX,FLOORY+4,vr,18,0,0,7);S.fill();S.restore();}
  // body
  /* L17 — the room's light lands on the UNIT. The rooms are three different
     lamps — sodium-warm, lab-cool, dispatch-violet — and the robots walked
     between them without changing colour, which is the classic tell of a
     sprite pasted over a background. One source-atop gradient tints the
     composed body from the lamp side down, in the room's cone colour, scaled
     by the lamp's own flicker; offline rooms instead cast the flat cold
     slate of a dead hall. The sprite alpha is untouched, so unitTop, unitBox
     and the envelope all still measure the same unit. */
  var kt2=STATE==="offline"?[96,110,136]:ROOM==="builder"?[255,201,135]:ROOM==="reviewer"?[150,196,245]:[176,150,240];
  var kta=STATE==="offline"?0.10:0.11*lamp.lit;
  RB.save();RB.setTransform(1,0,0,1,0,0);RB.globalCompositeOperation="source-atop";
  var ktg=RB.createLinearGradient(0,120,0,RH*0.92);
  ktg.addColorStop(0,rgba(kt2[0],kt2[1],kt2[2],kta));
  ktg.addColorStop(0.5,rgba(kt2[0],kt2[1],kt2[2],kta*0.35));
  ktg.addColorStop(1,rgba(kt2[0],kt2[1],kt2[2],0));
  RB.fillStyle=ktg;RB.fillRect(0,0,RW,RH);RB.restore();
  S.imageSmoothingEnabled=true;
  S.drawImage(robo,px,py,RW*sc,RH*sc);
  // rim additive
  S.save();S.globalCompositeOperation="lighter";S.globalAlpha=info.offl?0.5:0.95;S.drawImage(rrim,px,py,RW*sc,RH*sc);S.restore();
  // emissive -> glow buffer (scaled)
  G.save();G.globalCompositeOperation="lighter";G.drawImage(remit,px,py,RW*sc,RH*sc);G.restore();
  /* What the unit does to the air around it.
     Every one of these four moves a lot of energy and none of them touched the
     atmosphere they were standing in — the room had drifting fog and rising
     steam of its own, and the robot was a cut-out pasted in front of it. This
     is per-agent because it is the physics of each body: exhaust rises, feet
     raise dust, thrust pushes down and out, a hover skirt rings the floor.
     Cheap, and it is what stops the unit reading as a sticker. */
  if(!info.offl&&!reduced){
    var fy0=FLOORY;
    S.save();S.globalCompositeOperation="lighter";
    if(AGENT==="claude"){
      // heat shimmer off the twin exhaust stacks
      [-52,52].forEach(function(sxo,si2){var ex4=px+(260+sxo)*sc, ey4=py+200*sc;
        for(var p2=0;p2<3;p2++){var ph=((t*0.35+p2*0.33+si2*0.17)%1), yy=ey4-ph*86, rad=9+ph*26;
          var hg=S.createRadialGradient(ex4+Math.sin(t*1.6+p2+si2)*7*ph,yy,1,ex4,yy,rad);
          hg.addColorStop(0,rgba(255,168,96,0.10*(1-ph)*(info.work?1:0.45)));hg.addColorStop(1,"rgba(255,168,96,0)");
          S.fillStyle=hg;S.beginPath();S.arc(ex4,yy,rad,0,7);S.fill();}});
    } else if(AGENT==="codex"){
      // dust standing at the six feet — a heavy thing that has just settled
      (info.feet||[]).forEach(function(f,fi){var fx3=px+f.x*sc;
        var dph=((t*0.4+fi*0.19)%1), dr=7+dph*18;
        var dg=S.createRadialGradient(fx3,fy0-dph*13,1,fx3,fy0-dph*13,dr);
        dg.addColorStop(0,"rgba(96,140,130,"+(0.055*(1-dph))+")");dg.addColorStop(1,"rgba(96,140,130,0)");
        S.fillStyle=dg;S.beginPath();S.ellipse(fx3,fy0-dph*13,dr,dr*0.5,0,0,7);S.fill();});
    } else if(AGENT==="grok"){
      /* no thrusters any more. The stalker's air effect is its BREATH: slow
         vapor off the chin vents, drifting down and out and fading. It is the
         only motion on an idle grok besides the mane's sway — and that is the
         point: a predator holds still. */
      if(!info.offl)for(var b2=0;b2<2;b2++){var bp=((t*(info.work?0.5:0.3)+b2*0.5)%1);
        var vx0=ROBOX+(b2?9:-9)*sc+bp*10*(b2?1:-1), vy0=py+(info.hy+56)*sc+bp*15, br2=3+bp*9;
        var bg3=S.createRadialGradient(vx0,vy0,1,vx0,vy0,br2);
        bg3.addColorStop(0,"rgba(190,200,230,"+(0.10*(1-bp)).toFixed(3)+")");bg3.addColorStop(1,"rgba(190,200,230,0)");
        S.fillStyle=bg3;S.beginPath();S.ellipse(vx0,vy0,br2,br2*0.6,0,0,7);S.fill();}
    } else {
      // the torch column hits the deck: a hot core where it lands, spill
      // pushed out sideways, flickering with the throttle
      var tf=0.72+0.28*Math.sin(t*11);
      var tc=S.createRadialGradient(ROBOX,fy0+2,2,ROBOX,fy0+2,44);
      tc.addColorStop(0,"rgba(255,214,232,"+(0.20*tf*(info.work?1:0.55))+")");
      tc.addColorStop(0.5,"rgba(255,114,182,"+(0.11*tf*(info.work?1:0.55))+")");
      tc.addColorStop(1,"rgba(255,114,182,0)");
      S.fillStyle=tc;S.beginPath();S.ellipse(ROBOX,fy0+2,44,11,0,0,7);S.fill();
      [-1,1].forEach(function(sg2){var tg=S.createRadialGradient(ROBOX+sg2*30,fy0+2,2,ROBOX+sg2*30,fy0+2,72);
        tg.addColorStop(0,"rgba(255,114,182,"+(0.08*tf*(info.work?1:0.5))+")");tg.addColorStop(1,"rgba(255,114,182,0)");
        S.fillStyle=tg;S.beginPath();S.ellipse(ROBOX+sg2*36,fy0+3,72,11,0,0,7);S.fill();});
    }
    S.restore();
  }
  // working effect at the hand — role-specific
  var hx=px+info.hand.x*sc, hyy=py+info.hand.y*sc, visor={x:ROBOX,y:py+(info.hy+20)*sc};
  if(info.work){
    if(ROOM==="builder"){ // weld arc + spark shower
      var flick=0.4+0.42*Math.sin(t*40)+ (Math.random()<0.15?0.35:0);
      emit(function(c){c.save();c.globalCompositeOperation="lighter";var ag=c.createRadialGradient(hx,hyy,1,hx,hyy,20);ag.addColorStop(0,rgba(210,232,255,Math.min(0.9,flick)));ag.addColorStop(0.35,rgba(120,190,255,0.42*flick));ag.addColorStop(1,"rgba(90,160,255,0)");c.fillStyle=ag;c.beginPath();c.arc(hx,hyy,20,0,7);c.fill();c.fillStyle=rgba(255,255,255,Math.min(0.9,flick));c.beginPath();c.arc(hx,hyy,2.4,0,7);c.fill();c.restore();});
      /* A welding arc is the brightest thing in the building. It was lighting
         a 20px bubble and nothing else — not the plates it is held against,
         not the deck under it. Now it throws a hard, flickering pool on the
         floor, which is also what sells the sparks as hot rather than as
         orange confetti. */
      emit(function(c){c.save();c.globalCompositeOperation="lighter";
        var fp=c.createRadialGradient(hx,FLOORY,3,hx,FLOORY,150);
        fp.addColorStop(0,rgba(190,220,255,0.22*flick));
        fp.addColorStop(0.4,rgba(120,175,255,0.09*flick));
        fp.addColorStop(1,"rgba(90,150,255,0)");
        c.fillStyle=fp;c.beginPath();c.ellipse(hx,FLOORY+6,150,26,0,0,7);c.fill();c.restore();});
      if(!reduced&&Math.random()<0.55)for(var s=0;s<3;s++)sparks.push({x:hx,y:hyy,vx:(Math.random()-0.5)*1.5,vy:1.6+Math.random()*2.6,life:0.3+Math.random()*0.35});
    } else if(ROOM==="reviewer"){ // floating diff-scan hologram + sweep + beam
      var pw=66,ph=48,pxp=hx-6,pyp=hyy-ph-8;
      emit(function(c){c.save();c.globalCompositeOperation="lighter";c.strokeStyle="rgba(120,200,255,0.16)";c.lineWidth=2;c.beginPath();c.moveTo(visor.x,visor.y);c.lineTo(pxp+pw*0.42,pyp+ph*0.5);c.stroke();c.restore();});
      emit(function(c){c.save();c.fillStyle="rgba(90,180,255,0.06)";rr(c,pxp,pyp,pw,ph,4);c.fill();c.strokeStyle="rgba(120,205,255,0.7)";c.lineWidth=1;rr(c,pxp,pyp,pw,ph,4);c.stroke();
        for(var l=0;l<7;l++){var k=l%3,col=k===0?"90,210,130":k===1?"230,100,100":"90,150,210";c.fillStyle="rgba("+col+",0.72)";c.fillRect(pxp+7,pyp+8+l*5,10+((l*13)%40),2);}
        var sb=pyp+6+((t*46)%(ph-12));c.fillStyle="rgba(195,238,255,0.5)";c.fillRect(pxp+3,sb,pw-6,3);c.restore();});
      emit(function(c){var g5=c.createRadialGradient(hx,hyy,1,hx,hyy,12);g5.addColorStop(0,"rgba(150,210,255,0.6)");g5.addColorStop(1,"rgba(150,210,255,0)");c.fillStyle=g5;c.beginPath();c.arc(hx,hyy,12,0,7);c.fill();});
    } else { // triage: dispatch/comm hologram + routing blips + pulse ring
      var cw2=52,ch2=46,cxp=hx-4,cyp=hyy-ch2-8,pulse=0.5+0.5*Math.sin(t*5);
      emit(function(c){c.save();c.globalCompositeOperation="lighter";c.strokeStyle="rgba(201,139,255,0.16)";c.lineWidth=2;c.beginPath();c.moveTo(visor.x,visor.y);c.lineTo(cxp+cw2*0.42,cyp+ch2*0.5);c.stroke();c.restore();});
      emit(function(c){c.save();c.fillStyle="rgba(180,120,255,0.06)";rr(c,cxp,cyp,cw2,ch2,4);c.fill();c.strokeStyle="rgba(201,139,255,0.7)";c.lineWidth=1;rr(c,cxp,cyp,cw2,ch2,4);c.stroke();
        var cols=["247,189,78","92,180,255","95,206,155","255,114,182"];for(var ch=0;ch<4;ch++){var chx=cxp+8+ch*10;c.fillStyle="rgba(80,70,110,0.85)";c.fillRect(chx,cyp+9,2,ch2-16);if((ch+Math.floor(t*2))%2===0){c.fillStyle="rgba("+cols[ch]+",0.9)";c.fillRect(chx-1,cyp+9+((t*30+ch*7)%(ch2-20)),4,3);}}c.restore();});
      emit(function(c){c.save();c.globalCompositeOperation="lighter";c.strokeStyle="rgba(201,139,255,"+(0.5*pulse)+")";c.lineWidth=1.5;c.beginPath();c.arc(hx,hyy,4+9*pulse,0,7);c.stroke();c.fillStyle="rgba(224,186,255,0.85)";c.beginPath();c.arc(hx,hyy,2,0,7);c.fill();c.restore();});
    }
  }
  // offline: "!" alarm diamond above head
  if(info.offl){
    /* Above the UNIT, not above its visor — see unitTop. */
    var ax=px+260*sc, ay=py+unitTop()*sc-26 + Math.sin(t*3)*3;
    S.save();S.translate(ax,ay);S.rotate(Math.PI/4);
    S.fillStyle="#1a0d0f";S.fillRect(-11,-11,22,22);
    var p=0.5+0.5*Math.sin(t*6);S.fillStyle=rgba(255,60,50,0.5+0.5*p);S.fillRect(-8,-8,16,16);S.restore();
    S.fillStyle="#ffdcd8";S.font="700 15px "+"ui-monospace,monospace";S.textAlign="center";S.fillText("!",ax,ay+5);S.textAlign="left";
    emit(function(c){c.fillStyle=rgba(255,60,50,0.5*p);c.beginPath();c.arc(ax,ay,14,0,7);c.fill();});
  }
}
function stepSparks(dt){for(var i=sparks.length-1;i>=0;i--){var s=sparks[i];s.x+=s.vx;s.y+=s.vy;s.vy+=0.12;s.life-=dt;if(s.life<=0||s.y>FLOORY+6)sparks.splice(i,1);}}
function drawSparks(){S.save();S.globalCompositeOperation="lighter";sparks.forEach(function(s){var a=Math.min(1,s.life*2);S.fillStyle=rgba(255,200,120,a);S.fillRect(s.x,s.y,2,2);G.fillStyle=rgba(255,180,90,a*0.8);G.fillRect(s.x,s.y,2,2);});S.restore();}

/* ===================== THE DECK STATION =====================
   THE RE-THINK. Three designed objects, five polish loops, and it still read
   as a stool at the unit's ankles. Height was the symptom; here is the error.

   The station's base sat at FLOORY=612. FLOORY is where the UNIT'S FEET are.
   So the bench was never in front of the robot — it was standing beside it, at
   the same depth, and no amount of drawer faces and scorch marks fixes an
   object that is in the wrong place in the room. A bench at the same depth as
   a person, drawn at a third of their height, is a stool. That is what it was,
   and the eye read it correctly every time.

   The room has 108 pixels of deck between FLOORY and the bottom of the frame,
   and until now nothing has ever stood on them. That is the near plane, and it
   is where a foreground object belongs: base at y=668, well in front of the
   unit's feet, and therefore BIGGER — 268 wide against the old 204, 178 tall
   against the old 46. (It went out at 156 first, and read as a coffee table:
   a worktop at this depth has to reach the unit's waist-line on screen before
   the eye accepts it as something to stand at.)

   Three things follow from moving it, and they are what make it read as depth
   rather than as a bigger stool:

     1. We see its TOP. The camera sits around the unit's chest; anything whose
        surface is below that shows the surface. A worktop 178px up at this
        depth is below it, so the top face is a trapezoid — wider at the front,
        narrower at the back — and that single piece of perspective does more
        for depth than every edge highlight in the last five loops.
     2. It is BACKLIT. The lamp is behind it and above; the floor pool is
        behind it. So the front face is the dark side, lit only by bounce and
        by the station's own fixtures, and the back arris carries a rim. A
        near-plane object is a silhouette with a lit edge, not a lit box.
     3. It OCCLUDES. It crosses the unit's legs and hides the light pool at its
        feet, which is exactly the cue the old one could never give, because
        something at the same depth cannot get in front of anything.

   The station is drawn after the fog and the steam for the same reason. */
var DECK={cx:470, bw:268, fw:300, top:490, td:17, base:668};

/* L19 — a shadow is not black. A shadow is the floor with the key light
   subtracted, so on the builder's oiled amber it stays faintly brown, on the
   sealed lab floor it goes blue-black, and on the painted dispatch floor it
   carries a little violet. Every contact shadow in the room — feet, station,
   props — asks this one function instead of hard-coding 0,0,0, which is what
   ties twelve robots and three floors into the same light. */
function shadowRGB(){return ROOM==="builder"?"24,15,6":ROOM==="reviewer"?"4,10,20":"10,7,18";}

/* The floor the station stands on, and the pool it now hides. Losing the warm
   puddle at the unit's feet would be a real loss, so it is not lost: it reads
   as a halo spilling over the station's back edge, which is what a bright
   floor behind a dark object actually looks like. */
function deckGround(o){
  var d=DECK,lit=o.lit;
  emit(function(c){c.save();c.globalCompositeOperation="lighter";
    var g=c.createLinearGradient(0,d.top-22,0,d.top+4);
    g.addColorStop(0,rgba(o.glow[0],o.glow[1],o.glow[2],0));
    g.addColorStop(1,rgba(o.glow[0],o.glow[1],o.glow[2],(0.08+0.13*lit)*(o.st==="offline"?0.25:1)));
    c.fillStyle=g;c.fillRect(d.cx-d.bw/2-30,d.top-26,d.bw+60,32);c.restore();});
  // and the shadow it drops on the deck it stands on
  var s=S.createRadialGradient(d.cx,d.base+2,4,d.cx,d.base+2,d.fw*0.62);
  s.addColorStop(0,"rgba("+shadowRGB()+",0.62)");s.addColorStop(1,"rgba("+shadowRGB()+",0)");
  S.fillStyle=s;S.beginPath();S.ellipse(d.cx,d.base+2,d.fw*0.62,16,0,0,7);S.fill();
}

/* The carcass: front face, the two side slivers the perspective opens up, and
   the top. `lean` slides the bottom of the front face inward, which is the one
   silhouette control the three rooms differ on — a straight bench, a bench
   with a void under it, an angled console. */
function deckBody(o){
  var d=DECK,fx0=d.cx-d.fw/2,fx1=d.cx+d.fw/2,bx0=d.cx-d.bw/2,bx1=d.cx+d.bw/2;
  var ty=d.top,tf=d.top+d.td,by=d.base,lean=o.lean||0;
  // side slivers: the top is wider at the front, so the sides are visible
  S.fillStyle=o.side;
  poly(S,[[bx0,ty],[fx0,tf],[fx0+lean,by],[bx0,by-6]]);S.fill();
  poly(S,[[bx1,ty],[fx1,tf],[fx1-lean,by],[bx1,by-6]]);S.fill();
  // front face, darker toward the floor: this is the shadow side
  var g=S.createLinearGradient(0,tf,0,by);
  g.addColorStop(0,o.face);g.addColorStop(1,o.foot);
  S.fillStyle=g;poly(S,[[fx0,tf],[fx1,tf],[fx1-lean,by],[fx0+lean,by]]);S.fill();
  /* L4 — the worktop OVERHANGS the carcass. A slab that stops flush with the
     cabinet under it reads as a lid; every real bench top runs a few pixels
     proud and drops an apron edge, and that one strip of geometry is what
     separates "top of a box" from "surface you work at". The top face flares
     to the overhang at the front, the apron takes the leading light, and the
     face below starts in its shadow. */
  var ov=6,ax0=fx0-ov,ax1=fx1+ov,aw=d.fw+ov*2,ab=tf+8;
  // the top face, in perspective, out to the overhang
  var tg=S.createLinearGradient(0,ty,0,tf);
  tg.addColorStop(0,o.topBack);tg.addColorStop(1,o.topFront);
  S.fillStyle=tg;poly(S,[[bx0,ty],[bx1,ty],[ax1,tf],[ax0,tf]]);S.fill();
  // the key, falling off from under the lamp, on the top face only
  var kg=S.createLinearGradient(bx0,0,bx1,0),mid=Math.max(0.1,Math.min(0.9,(LAMPX-bx0)/d.bw));
  kg.addColorStop(0,rgba(o.key[0],o.key[1],o.key[2],0));
  kg.addColorStop(mid,rgba(o.key[0],o.key[1],o.key[2],0.05+0.08*o.lit));
  kg.addColorStop(1,rgba(o.key[0],o.key[1],o.key[2],0));
  S.fillStyle=kg;poly(S,[[bx0,ty],[bx1,ty],[ax1,tf],[ax0,tf]]);S.fill();
  /* The rim on the back arris — the whole reason a backlit object reads.
     2.2px, not 1.6: the god-view cell scales the room by ~0.26, and below
     ~2px this line — the station's whole silhouette cue — rounds to nothing
     at cell scale. At full size the difference reads as edge wear. */
  S.fillStyle=rgba(o.key[0],o.key[1],o.key[2],0.16+0.26*o.lit);S.fillRect(bx0,ty,d.bw,2.2);
  /* L7 — the other thing behind the station is the UNIT, and the unit has a
     lit core in its chest. The lamp's rim is even and pale; the unit's is a
     second, vendor-coloured swell in the middle of the back edge, strongest
     when the unit is working and gone when it is offline. Four vendors, four
     colours, one line — and the bench finally knows who is standing at it. */
  var us=STATE==="working"?1:STATE==="idle"?0.45:0;
  if(us>0){var uc=VENDORCOL(AGENT),uw=130;
    var ug=S.createLinearGradient(d.cx-uw/2,0,d.cx+uw/2,0);
    ug.addColorStop(0,hexA(uc,0));ug.addColorStop(0.5,hexA(uc,0.30*us));ug.addColorStop(1,hexA(uc,0));
    S.fillStyle=ug;S.fillRect(d.cx-uw/2,ty,uw,2);
    var ug2=S.createLinearGradient(d.cx-uw/2,0,d.cx+uw/2,0);
    ug2.addColorStop(0,hexA(uc,0));ug2.addColorStop(0.5,hexA(uc,0.08*us));ug2.addColorStop(1,hexA(uc,0));
    S.fillStyle=ug2;S.fillRect(d.cx-uw/2,ty+2,uw,6);
    emit(function(c){var eg=c.createLinearGradient(d.cx-uw/2,0,d.cx+uw/2,0);
      eg.addColorStop(0,hexA(uc,0));eg.addColorStop(0.5,hexA(uc,0.18*us));eg.addColorStop(1,hexA(uc,0));
      c.fillStyle=eg;c.fillRect(d.cx-uw/2,ty-1,uw,3);});}
  // the apron: end grain of the slab, catching bounce off the deck
  var ag=S.createLinearGradient(0,tf,0,ab);
  ag.addColorStop(0,o.topFront);ag.addColorStop(1,o.foot);
  S.fillStyle=ag;S.fillRect(ax0,tf,aw,ab-tf);
  S.fillStyle=rgba(o.key[0],o.key[1],o.key[2],0.10+0.09*o.lit);S.fillRect(ax0,tf,aw,2.2);
  S.fillStyle="rgba(0,0,0,0.35)";S.fillRect(ax0,tf,2,ab-tf);S.fillRect(ax1-2,tf,2,ab-tf);
  S.fillStyle="rgba(0,0,0,0.45)";S.fillRect(ax0,ab-1.5,aw,1.5);
  S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(fx0,ab,d.fw,3);
  /* L8 — offline is a LIGHTING state, and the near plane was opting out of
     it. When the lamp is dead the beacon is the only thing burning, it is up
     and to the LEFT, and it pulses — so the station's left edges catch a red
     that breathes: the left half of the back arris, the left end of the
     apron, the left side sliver. The right stays black, which is what makes
     the red read as a direction instead of a tint. */
  if(STATE==="offline"&&beaconPulse>0){var bp=beaconPulse;
    var rg2=S.createLinearGradient(bx0,0,bx0+d.bw*0.6,0);
    rg2.addColorStop(0,"rgba(255,64,52,"+(0.16+0.16*bp)+")");rg2.addColorStop(1,"rgba(255,64,52,0)");
    S.fillStyle=rg2;S.fillRect(bx0,ty,d.bw*0.6,1.6);
    S.fillStyle="rgba(255,64,52,"+(0.07+0.08*bp)+")";S.fillRect(ax0,tf,26,1.6);
    S.fillStyle="rgba(255,64,52,"+(0.04+0.05*bp)+")";S.fillRect(ax0,tf,2,ab-tf);
    var rg3=S.createLinearGradient(0,ty,0,by);
    rg3.addColorStop(0,"rgba(255,64,52,"+(0.05+0.05*bp)+")");rg3.addColorStop(1,"rgba(255,64,52,0)");
    S.fillStyle=rg3;poly(S,[[bx0,ty],[fx0,tf],[fx0+lean,by],[bx0,by-6]]);S.fill();}
  /* R1 — the toe, and the floor it stands on. Without a plinth the body just
     faded into the dark deck and the station had no bottom; a near-plane
     object that does not touch the floor floats exactly as badly as one drawn
     at the wrong depth. */
  S.fillStyle="rgba(0,0,0,0.62)";S.fillRect(fx0+lean+4,by-11,d.fw-lean*2-8,11);
  S.fillStyle=o.toe;S.fillRect(fx0+lean+4,by-11,d.fw-lean*2-8,2);
  S.fillStyle="rgba(0,0,0,0.7)";S.fillRect(fx0+lean,by-3,d.fw-lean*2,3);
  var fl=S.createLinearGradient(0,by-3,0,by+7);
  fl.addColorStop(0,"rgba(0,0,0,0.6)");fl.addColorStop(1,"rgba(0,0,0,0)");
  S.fillStyle=fl;S.fillRect(fx0-14,by-3,d.fw+28,10);
  return {fx0:fx0,fx1:fx1,bx0:bx0,bx1:bx1,ty:ty,tf:tf,by:by};
}

/* A point ON the top face, in its own perspective: u across (0..1), v back to
   front (0..1). Everything that sits on a station is placed with this, so the
   props share the surface's perspective instead of floating in screen space. */
function deckAt(g,u,v){
  var xb=g.bx0+(g.bx1-g.bx0)*u, xf=g.fx0+(g.fx1-g.fx0)*u;
  return {x:xb+(xf-xb)*v, y:g.ty+(g.tf-g.ty)*v};
}
/* A thing standing on the surface: its footprint sits at v, its height rises
   from there, and it is scaled by how near the front it is. */
function deckStand(g,u,v,h){var p=deckAt(g,u,v);return {x:p.x,y:p.y,s:0.92+0.22*v,top:p.y-h};}

/* Fasteners, panels, wear — carried over from loops 2 and 3, re-fitted. */
function drawerFace(x,y,w,h,face,edge,pull){
  S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(x,y,w,h);
  S.fillStyle=face;S.fillRect(x+1,y+1,w-2,h-2);
  S.fillStyle=edge;S.fillRect(x+1,y+1,w-2,1);
  S.fillStyle="rgba(0,0,0,0.35)";S.fillRect(x+1,y+h-2,w-2,1);
  S.fillStyle=pull;S.fillRect(x+w/2-13,y+h/2-1,26,2);
  S.fillStyle="rgba(0,0,0,0.4)";S.fillRect(x+w/2-13,y+h/2+1,26,1);
}
function wornEdge(x,y,w,col,seed){
  S.fillStyle=col;
  for(var i=0;i<w;i+=3){var h=(Math.sin((x+i)*12.9898+seed)*43758.5453)%1;
    if(h<0)h+=1; if(h>0.34)S.fillRect(x+i,y,2,1);}
}
function scorch(cx,cy,rx,ry,a){
  var g=S.createRadialGradient(cx,cy,0.5,cx,cy,rx);
  g.addColorStop(0,"rgba(18,12,8,"+a+")");g.addColorStop(0.6,"rgba(24,16,10,"+(a*0.5)+")");
  g.addColorStop(1,"rgba(24,16,10,0)");
  S.fillStyle=g;S.beginPath();S.ellipse(cx,cy,rx,ry,0,0,7);S.fill();
}
function brushed(x,y,w,h,a){
  S.save();S.globalAlpha=a;
  for(var i=0;i<w;i+=2){var v=(Math.sin((x+i)*7.13)*0.5+0.5);
    S.fillStyle=v>0.5?"rgba(255,255,255,0.5)":"rgba(0,0,0,0.5)";S.fillRect(x+i,y,1,h);}
  S.restore();
}
function hazard(x,y,w,h,a){
  S.save();S.globalAlpha=a;
  for(var i=0;i<w;i+=12){S.fillStyle=(i/12)%2?"#0d1017":"#c9a227";S.fillRect(x+i,y,12,h);}
  S.restore();
}
/* R2 — a louvred panel. The front face is the biggest surface in the frame
   now, and on all three stations most of it was a flat rectangle. Real cabinet
   doors breathe. */
function louvres(x,y,w,h,n,dark,lite){
  var g=h/n;
  for(var i=0;i<n;i++){var yy=y+i*g;
    S.fillStyle=dark;S.fillRect(x,yy,w,g*0.55);
    S.fillStyle=lite;S.fillRect(x,yy+g*0.55,w,1);}
}
/* A cable, hung in a catenary from a to b and run down to the floor. */
function cableHang(x0,y0,x1,y1,sag,col,wd){
  S.strokeStyle=col;S.lineWidth=wd||2.5;S.beginPath();
  S.moveTo(x0,y0);S.bezierCurveTo(x0+(x1-x0)*0.3,y0+sag,x0+(x1-x0)*0.7,y0+sag,x1,y1);S.stroke();
}
function assetPlate(x,y,w,tone,ink){
  S.fillStyle=tone;S.fillRect(x,y,w,8);
  S.fillStyle="rgba(0,0,0,0.35)";S.fillRect(x,y+8,w,1);
  S.fillStyle=ink;S.fillRect(x+2,y+2,w*0.42,1.5);S.fillRect(x+2,y+5,w*0.66,1.5);
}
/* A fixture's light landing on what is around it — including, now, the unit's
   legs, because the station is in front of them. */
function spill(cx,cy,rx,ry,col,a){
  emit(function(c){c.save();c.globalCompositeOperation="lighter";
    var g=c.createRadialGradient(cx,cy,0.5,cx,cy,rx);
    g.addColorStop(0,rgba(col[0],col[1],col[2],a));g.addColorStop(1,rgba(col[0],col[1],col[2],0));
    c.fillStyle=g;c.beginPath();c.ellipse(cx,cy,rx,ry,0,0,7);c.fill();c.restore();});
}

function deckStation(t,lit,st){
  /* L2 — the near plane occludes LIGHT, not just paint. The glow buffer is
     composited over the scene with three blurred passes, so every emissive
     behind the station — above all the lamp's floor pool at FLOORY — bloomed
     straight through the carcass and lay on its front face as a bright fog,
     which un-did the occlusion the move to the near plane bought. Punch the
     station's silhouette out of the glow buffer first; the station's own
     fixtures emit after this, so they still bloom, and the blur still wraps
     the pool's light around the edges the way real bloom hugs a silhouette. */
  var dd=DECK,ln=ROOM==="triage"?26:0,nx0=dd.cx-dd.fw/2,nx1=dd.cx+dd.fw/2;
  G.save();G.globalCompositeOperation="destination-out";G.fillStyle="#000";
  poly(G,[[dd.cx-dd.bw/2,dd.top],[dd.cx+dd.bw/2,dd.top],[nx1+6,dd.top+dd.td],
    [nx1-ln,dd.base],[nx0+ln,dd.base],[nx0-6,dd.top+dd.td]]);G.fill();G.restore();
  if(ROOM==="builder")fabTable(t,lit,st);
  else if(ROOM==="reviewer")inspectBench(t,lit,st);
  else plotTable(t,lit,st);
  /* L16 — the unit SHADES the bench. The lamp hangs directly over the unit
     and the worktop stands in front of and below it, so the strip of top
     face nearest the unit is the strip the unit's own body keeps the light
     off. Width comes from the footprint the sprite actually reported — wide
     for codex's straddle, narrow for claude — and a hovering unit throws it
     softer and fainter, by the same height rule the floor shadows obey. It
     scales with the lamp, so an offline room loses it with everything else. */
  if(lit>0.02&&lastAnchors&&lastAnchors.feet&&lastAnchors.feet.length){
    var sm=1e9,sx2=-1e9,slift=0;
    lastAnchors.feet.forEach(function(f){sm=Math.min(sm,f.x-f.w);sx2=Math.max(sx2,f.x+f.w);slift+=Math.max(0,FLOORY-f.y);});
    slift/=lastAnchors.feet.length;
    var uw2=Math.max(70,Math.min(250,(sx2-sm)*1.15)),ucx=(sm+sx2)/2;
    var soft=1+Math.min(1.6,slift/70),ua=0.30*lit/Math.pow(soft,1.2);
    S.save();
    poly(S,[[dd.cx-dd.bw/2,dd.top],[dd.cx+dd.bw/2,dd.top],[nx1+6,dd.top+dd.td],[nx0-6,dd.top+dd.td]]);S.clip();
    var us2=S.createRadialGradient(ucx,dd.top+dd.td*0.32,2,ucx,dd.top+dd.td*0.32,uw2*0.55*soft);
    us2.addColorStop(0,"rgba(2,4,8,"+ua.toFixed(3)+")");us2.addColorStop(1,"rgba(2,4,8,0)");
    S.fillStyle=us2;S.beginPath();S.ellipse(ucx,dd.top+dd.td*0.32,uw2*0.55*soft,dd.td*0.6,0,0,7);S.fill();
    S.restore();
  }
  /* L18 — the top REFLECTS who stands at it. Glass, acrylic and brushed
     steel all bounce some image back, in that order, and none of them did:
     the strip of worktop under each unit stayed the same whether claude or
     kimi stood over it. The composed sprite is drawn again, flipped about
     the worktop line and compressed to the top face's 17px of perspective,
     clipped to the face, blurrier the rougher the material — a mirror line
     on the glass, a coloured smear on the steel. A hovering unit's
     reflection detaches from the back edge by the same lift that holds the
     unit off the floor, because that is where a mirror would put it. */
  if(lastAnchors&&lastAnchors.sprite){
    var ra=ROOM==="reviewer"?0.12:ROOM==="triage"?0.085:0.05;
    if(STATE==="offline")ra*=0.45;
    var sp2=lastAnchors.sprite;
    S.save();
    poly(S,[[dd.cx-dd.bw/2,dd.top],[dd.cx+dd.bw/2,dd.top],[nx1+6,dd.top+dd.td],[nx0-6,dd.top+dd.td]]);S.clip();
    S.globalAlpha=ra;
    S.filter=ROOM==="builder"?"blur(3px)":ROOM==="triage"?"blur(1.5px)":"blur(1px)";
    S.setTransform(1,0,0,-0.22,0,dd.top+FLOORY*0.22);
    S.drawImage(robo,sp2.x,sp2.y,RW*sp2.s,RH*sp2.s);
    S.restore();
  }
  /* R1 — the last thing the near plane needs: to be nearer. Everything at
     this depth is on the camera's side of the room's haze and the lamp's
     throw, so it sits a stop under the mid-plane and falls off further toward
     the bottom of the frame, where no light reaches at all. Without it the
     station reads as a well-drawn object at the same distance as everything
     else, which is the thing this whole re-think was about. */
  var d=DECK,g2=S.createLinearGradient(0,d.top,0,d.base+8);
  g2.addColorStop(0,"rgba(3,6,12,0.10)");g2.addColorStop(0.55,"rgba(3,6,12,0.20)");
  g2.addColorStop(1,"rgba(3,6,12,0.42)");
  S.fillStyle=g2;S.fillRect(d.cx-d.fw/2-6,d.top,d.fw+12,d.base-d.top+8);
}

/* L6 — the companion prop, per room: the near plane's second citizen. Drawn
   with the station's rules — silhouette first, one rim where the room's light
   catches the top edge, glow buffer punched out behind it (L2), the same
   near-plane grade laid over it — because an object at this depth that broke
   any of those rules would pop back to the mid plane. */
function nearSideProp(t,lit,st){
  var off=st==="offline";
  var key=ROOM==="builder"?[255,214,170]:ROOM==="reviewer"?[196,232,255]:[190,180,255];
  var ka=(0.14+0.20*lit)*(off?0.35:1);
  LAYOUT.nearSide[ROOM].forEach(function(z,zi){
  var x=z[1],w=z[3],by=z[2]+z[4];
  G.save();G.globalCompositeOperation="destination-out";G.fillStyle="#000";
  G.fillRect(x-2,z[2]-2,w+4,z[4]+4);G.restore();
  // floor contact first, so the body stands on something
  var cs=S.createRadialGradient(x+w/2,by+2,3,x+w/2,by+2,w*0.72);
  cs.addColorStop(0,"rgba("+shadowRGB()+",0.58)");cs.addColorStop(1,"rgba("+shadowRGB()+",0)");
  S.fillStyle=cs;S.beginPath();S.ellipse(x+w/2,by+2,w*0.72,10,0,0,7);S.fill();
  if(zi===1){
    /* the left props (L13), one per room */
    if(ROOM==="builder"){
      // a pallet of stock billets, layered crosswise the way stock is racked
      S.fillStyle="#0e0a07";[x+6,x+w/2-6,x+w-18].forEach(function(bx3){S.fillRect(bx3,by-8,12,8);});
      S.fillStyle="#1a140d";S.fillRect(x,by-13,w,5);
      S.fillStyle=rgba(key[0],key[1],key[2],ka*0.4);S.fillRect(x,by-13,w,1);
      [[x+6,by-22,w-12,9,"#171310"],[x+10,by-31,w-24,9,"#1c1712"],[x+16,by-40,52,9,"#181209"]].forEach(function(b4){
        S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(b4[0],b4[1]+b4[3]-2,b4[2],2);
        S.fillStyle=b4[4];S.fillRect(b4[0],b4[1],b4[2],b4[3]);
        S.fillStyle=rgba(key[0],key[1],key[2],ka*0.55);S.fillRect(b4[0],b4[1],b4[2],1.2);});
      S.strokeStyle="#241c12";S.lineWidth=3;
      S.beginPath();S.moveTo(x+w-4,by-2);S.lineTo(x+w-26,by-64);S.stroke();
    } else if(ROOM==="reviewer"){
      // the lab stool nobody is sitting on — a review lab at 2am
      var scx=x+w/2,seatY=z[2]+10;
      S.fillStyle="#10161f";S.fillRect(scx-2.5,seatY,5,by-8-seatY);
      S.strokeStyle="#0e141d";S.lineWidth=3.5;
      [[-20,0],[20,0]].forEach(function(lg){S.beginPath();S.moveTo(scx,by-26);S.lineTo(scx+lg[0],by-5);S.stroke();
        S.fillStyle="#0a0e15";S.beginPath();S.arc(scx+lg[0],by-4,3.4,0,7);S.fill();});
      S.strokeStyle="rgba(150,180,215,0.14)";S.lineWidth=1.4;
      S.beginPath();S.ellipse(scx,by-30,13,3.6,0,0,7);S.stroke();
      S.fillStyle="rgba(0,0,0,0.5)";S.beginPath();S.ellipse(scx,seatY+3,23,6,0,0,7);S.fill();
      S.fillStyle="#1b2530";S.beginPath();S.ellipse(scx,seatY,22,5.5,0,0,7);S.fill();
      S.fillStyle=rgba(key[0],key[1],key[2],ka*0.9);S.beginPath();S.ellipse(scx,seatY-1,22,5.5,0,3.4,6.0);S.stroke();
      // clipboard left against the post, mid-review
      S.save();S.translate(scx-14,by-3);S.rotate(-0.22);
      S.fillStyle="#141b26";S.fillRect(-9,-30,18,30);
      S.fillStyle="rgba(200,224,248,0.22)";S.fillRect(-6,-26,12,1.6);S.fillRect(-6,-21,9,1.6);
      S.fillStyle="#2a3442";S.fillRect(-4,-32,8,4);S.restore();
    } else {
      // queue stanchions with sagging tape: dispatch's own crowd control
      var p0=x+10,p1=x+w-10,pty=z[2]+10;
      [p0,p1].forEach(function(px3){
        S.fillStyle="#0a0e18";S.beginPath();S.ellipse(px3,by-2,10,3.4,0,0,7);S.fill();
        S.fillStyle="#10162a";S.fillRect(px3-2,pty,4,by-4-pty);
        S.fillStyle="#1e2740";S.beginPath();S.arc(px3,pty,4.5,0,7);S.fill();
        S.strokeStyle=rgba(key[0],key[1],key[2],ka*0.9);S.lineWidth=1.2;
        S.beginPath();S.arc(px3,pty,4.5,3.6,5.6);S.stroke();});
      S.strokeStyle="rgba(201,162,39,"+(off?0.14:0.30)+")";S.lineWidth=3;
      S.beginPath();S.moveTo(p0+3,pty+6);S.quadraticCurveTo((p0+p1)/2,pty+22,p1-3,pty+6);S.stroke();
      S.strokeStyle="rgba(0,0,0,0.4)";S.lineWidth=1;
      S.beginPath();S.moveTo(p0+3,pty+8);S.quadraticCurveTo((p0+p1)/2,pty+24,p1-3,pty+8);S.stroke();
      S.fillStyle="#141a2c";S.fillRect((p0+p1)/2-4,pty+20,8,10);
      if(!off){S.fillStyle="rgba(247,189,78,0.65)";S.fillRect((p0+p1)/2-1.5,pty+23,3,3);}
    }
  } else if(ROOM==="builder"){
    // a spent-stock drum, lid askew, offcuts leaning on its shoulder
    var dx=x+4,dw=w-14,ty2=z[2]+14;
    S.fillStyle="#0d0a07";S.beginPath();S.ellipse(dx+dw/2,by-3,dw/2,6,0,0,7);S.fill();
    var bg=S.createLinearGradient(dx,0,dx+dw,0);
    bg.addColorStop(0,"#1c1610");bg.addColorStop(0.42,"#12100b");bg.addColorStop(1,"#0a0906");
    S.fillStyle=bg;S.fillRect(dx,ty2,dw,by-3-ty2);
    S.fillStyle="#181310";S.beginPath();S.ellipse(dx+dw/2,ty2,dw/2,5.5,0,0,7);S.fill();
    S.strokeStyle=rgba(key[0],key[1],key[2],ka);S.lineWidth=1.4;
    S.beginPath();S.ellipse(dx+dw/2,ty2,dw/2,5.5,0,3.3,6.1);S.stroke();
    [0.3,0.62].forEach(function(rv){var ry=ty2+(by-3-ty2)*rv;
      S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(dx,ry,dw,2.5);
      S.fillStyle=rgba(key[0],key[1],key[2],ka*0.4);S.fillRect(dx,ry-1,dw,1);});
    scorch(dx+dw/2,ty2+2,16,4,0.5);
    for(var rd=0;rd<3;rd++){S.strokeStyle=["#241c12","#1a150e","#2a2014"][rd];S.lineWidth=2.6;
      S.beginPath();S.moveTo(x+w-4-rd*5,by);S.lineTo(dx+dw-8-rd*4,ty2-26+rd*5);S.stroke();}
  } else if(ROOM==="reviewer"){
    // the archive cart: what the low bay in the bench is FOR, on its way out
    var px0=x+5,px1=x+w-5,sh1=z[2]+30,sh2=z[2]+78;
    S.strokeStyle="#141c28";S.lineWidth=4;
    [[px0,sh1],[px1,sh1]].forEach(function(pp){S.beginPath();S.moveTo(pp[0],pp[1]-16);S.lineTo(pp[0],by-6);S.stroke();});
    [sh1,sh2].forEach(function(sy){
      S.fillStyle="#0e1520";S.fillRect(px0-3,sy,px1-px0+6,7);
      S.fillStyle=rgba(key[0],key[1],key[2],ka*1.1);S.fillRect(px0-3,sy,px1-px0+6,1.4);});
    [[px0+2,0],[px1-10,0]].forEach(function(cw){
      S.fillStyle="#0a0e15";S.beginPath();S.arc(cw[0]+4,by-4,4.5,0,7);S.fill();
      S.fillStyle="rgba(150,180,215,0.18)";S.beginPath();S.arc(cw[0]+3,by-5.5,1.6,0,7);S.fill();});
    // two box files on top, one slumped open on the lower shelf
    S.fillStyle="#1d2735";S.fillRect(px0+4,sh1-24,26,24);
    S.fillStyle="#232f3f";S.fillRect(px0+34,sh1-20,24,20);
    S.fillStyle=rgba(key[0],key[1],key[2],ka*0.7);S.fillRect(px0+4,sh1-24,26,1.2);S.fillRect(px0+34,sh1-20,24,1.2);
    S.fillStyle="rgba(170,200,235,0.25)";S.fillRect(px0+9,sh1-16,16,2);
    S.fillStyle="#182230";S.fillRect(px0+8,sh2-14,34,14);
    S.fillStyle="rgba(200,224,248,0.30)";for(var pg=0;pg<3;pg++)S.fillRect(px0+10+pg,sh2-14-pg*2.5,30-pg*2,2);
  } else {
    // the cable reel dispatch runs on, half unwound toward the tube station
    var cx2=x+w/2,cy2=by-40,R=34;
    S.fillStyle="#0c1018";S.beginPath();S.arc(cx2,cy2,R,0,7);S.fill();
    S.fillStyle="#131a2c";S.beginPath();S.arc(cx2,cy2,R-5,0,7);S.fill();
    S.fillStyle="#0a0d16";S.beginPath();S.arc(cx2,cy2,R-14,0,7);S.fill();
    for(var wr=0;wr<3;wr++){S.strokeStyle="rgba(30,38,60,0.9)";S.lineWidth=2;
      S.beginPath();S.arc(cx2,cy2,R-16-wr*4,0,7);S.stroke();}
    S.fillStyle="#1e2740";S.beginPath();S.arc(cx2,cy2,5,0,7);S.fill();
    S.strokeStyle=rgba(key[0],key[1],key[2],ka);S.lineWidth=1.6;
    S.beginPath();S.arc(cx2,cy2,R,3.6,5.4);S.stroke();
    S.strokeStyle="#141a2c";S.lineWidth=5;
    S.beginPath();S.moveTo(cx2-R+4,by-4);S.lineTo(cx2+R-4,by-4);S.stroke();
    S.strokeStyle="#10162a";S.lineWidth=3.5;
    S.beginPath();S.moveTo(cx2+R-10,cy2+R-14);S.quadraticCurveTo(cx2+R+26,by+2,cx2+R+52,by-2);S.stroke();
    if(!off){S.fillStyle="rgba(247,189,78,0.7)";S.fillRect(cx2-3,cy2-R-7,6,4);
      spill(cx2,cy2-R-5,10,6,[247,189,78],0.10);}
  }
  // the near-plane grade — same stop under the mid-plane the station sits
  var ng2=S.createLinearGradient(0,z[2],0,by+6);
  ng2.addColorStop(0,"rgba(3,6,12,0.10)");ng2.addColorStop(1,"rgba(3,6,12,0.40)");
  S.fillStyle=ng2;S.fillRect(x-4,z[2],w+8,z[4]+8);
  });
  /* L14 — the plane is WIRED together. Station and companions stood in the
     same depth with nothing passing between them, which is how a stage set
     stands. What actually crosses a shop floor is at ankle height: the
     welding lead runs on to the drum it was cut over, the dispatch loom runs
     out to its reel, and the review lab — which runs on paper, not power —
     has dropped two sheets on the way to the cart. All of it lies in the
     band the foreground lip half-swallows, which is where ankle clutter
     belongs. */
  if(ROOM==="builder"){
    // bench edge → dips through the out-of-focus band → climbs the drum rim
    S.strokeStyle="rgba(8,6,5,0.92)";S.lineWidth=3.5;
    S.beginPath();S.moveTo(628,642);S.quadraticCurveTo(726,672,808,662);
    S.quadraticCurveTo(892,650,944,588);S.stroke();
    S.strokeStyle="rgba(120,90,60,0.20)";S.lineWidth=1.2;
    S.beginPath();S.moveTo(628,640.5);S.quadraticCurveTo(726,670.5,808,660.5);S.stroke();
    // the slack, coiled where it lands on the rim
    S.strokeStyle="rgba(10,8,6,0.9)";S.lineWidth=2.6;
    S.beginPath();S.arc(950,592,7,0,7);S.stroke();
    S.beginPath();S.arc(950,593,4,0,7);S.stroke();
  } else if(ROOM==="reviewer"){
    // the lab runs on paper: two sheets dropped between the bench and the cart
    [[686,636,-0.06],[742,645,0.09]].forEach(function(sh3){
      S.save();S.translate(sh3[0],sh3[1]);S.rotate(sh3[2]);
      S.fillStyle="rgba(0,0,0,0.4)";S.fillRect(-13,2,27,3);
      S.fillStyle="rgba(163,180,200,0.48)";S.fillRect(-13,-2,26,4);
      S.fillStyle="rgba(210,226,244,0.32)";S.fillRect(-13,-2,26,1.2);
      S.fillStyle="rgba(60,74,92,0.5)";S.fillRect(-9,-0.5,15,1);S.restore();});
  } else {
    // console loom → dips → rises to join the reel's wind
    S.strokeStyle="rgba(10,12,22,0.92)";S.lineWidth=3.5;
    S.beginPath();S.moveTo(628,640);S.quadraticCurveTo(742,674,836,662);
    S.quadraticCurveTo(920,650,962,608);S.stroke();
    S.strokeStyle="rgba(120,130,190,0.16)";S.lineWidth=1.2;
    S.beginPath();S.moveTo(628,638.5);S.quadraticCurveTo(742,672.5,836,660.5);S.stroke();
  }
}

/* L20 — the air in FRONT of the subject. The lamp cone has had motes since
   loop 5, and they stop at the unit's depth, so the space between the near
   plane and the camera reads as vacuum. A handful of larger, slower, blurred
   motes now drift across the near band — bigger and softer than the cone's
   because near dust is out of focus for the same reason the nearEdge is, and
   moving mostly sideways because down here we are below the lamp's draft.
   Keyed to the room's cone colour, dimmed but not killed offline (dust does
   not care), pinned still under reduced motion. */
function nearMotes(t,st){
  if(reduced)return;
  var mc=ROOM==="builder"?[255,214,160]:ROOM==="reviewer"?[186,218,250]:[206,190,255];
  var dim=st==="offline"?0.35:1;
  S.save();S.filter="blur(2.5px)";S.globalCompositeOperation="lighter";
  for(var i=0;i<6;i++){
    var dir=i%2?1:-1, sp5=0.011+0.006*(i%3);
    var ph=(t*sp5+i*0.173)%1, x=dir>0?(-70+ph*(DW+140)):(DW+70-ph*(DW+140));
    var y=436+((i*89)%224)+Math.sin(t*0.42+i*1.9)*13;
    var r=3.2+(i%3)*1.8, a=(0.06+0.038*Math.sin(t*0.7+i*2.3))*dim;
    if(a<=0)continue;
    S.fillStyle=rgba(mc[0],mc[1],mc[2],a);S.beginPath();S.arc(x,y,r,0,7);S.fill();
  }
  S.restore();
}

/* BUILDER — a welding bench, straight-sided and heavy. */
function fabTable(t,lit,st){
  var on=st!=="offline";
  deckGround({lit:lit,st:st,glow:[255,186,120]});
  var g=deckBody({lit:lit,lean:0,key:[255,214,170],toe:"#3a2c1c",
    topBack:"#2d353f",topFront:"#222932",face:"#12171f",foot:"#090d13",side:"#0c1116"});
  brushed(g.bx0,g.ty+1,DECK.bw,DECK.td-2,0.05);
  wornEdge(g.fx0,g.tf-2,DECK.fw,"rgba(214,196,168,0.20)",11.3);
  /* L5 — the top is a MATERIAL again. Going dark (right) and tilting into
     perspective (also right) left all three tops the same anonymous gradient;
     what says "steel plate" at this size is the seams between the plates and
     the bolts that hold them down, each drawn in the surface's own
     perspective so they recede with it. */
  [0.34,0.67].forEach(function(su){var sa=deckAt(g,su,0),sb=deckAt(g,su,1);
    S.strokeStyle="rgba(0,0,0,0.4)";S.lineWidth=1.2;
    S.beginPath();S.moveTo(sa.x,sa.y+1);S.lineTo(sb.x,sb.y-1);S.stroke();
    S.strokeStyle="rgba(214,196,168,0.10)";S.lineWidth=1;
    S.beginPath();S.moveTo(sa.x+1.4,sa.y+1);S.lineTo(sb.x+1.4,sb.y-1);S.stroke();});
  [[0.05,0.22],[0.30,0.8],[0.63,0.8],[0.96,0.22],[0.05,0.8],[0.96,0.8]].forEach(function(bp){
    var p2=deckAt(g,bp[0],bp[1]);rivet(S,p2.x,p2.y,"rgba(214,196,168,0.30)");});

  // front face: a bank of drawers, hazard tape along the toe, asset plate
  var fw=DECK.fw,fy=g.tf+8;
  for(var d=0;d<3;d++)drawerFace(g.fx0+16,fy+d*26,132,24,"#2a2016","#4a3722","rgba(200,150,90,0.6)");
  /* L3 — the face re-cut for the height. The drawer bank and the door were
     composed for the 156px body; at 178 both stopped 60px short of the toe
     and the bottom of the face was a void. Real benches keep the shallow
     drawers at hand height and one DEEP drawer at the bottom, so that is
     what the height buys: a fourth, taller drawer, and the door runs on to
     the plinth. */
  drawerFace(g.fx0+16,fy+78,132,40,"#251c13","#42311e","rgba(200,150,90,0.5)");
  S.fillStyle="rgba(255,190,130,0.05)";S.fillRect(g.fx0+16,fy,132,1);
  hazard(g.fx0+170,g.by-16,110,5,0.4);
  /* The cabinet door: a frame, a louvred vent, a handle with a shadow, and a
     corner where the paint has gone. A flat panel is a hole in the picture. */
  S.fillStyle="rgba(0,0,0,0.45)";S.fillRect(g.fx0+164,fy,120,118);
  S.fillStyle="#221a10";S.fillRect(g.fx0+166,fy+2,116,114);
  S.fillStyle="rgba(190,150,100,0.14)";S.fillRect(g.fx0+166,fy+2,116,1);
  louvres(g.fx0+176,fy+10,96,30,5,"rgba(0,0,0,0.55)","rgba(190,150,100,0.16)");
  louvres(g.fx0+176,fy+78,96,26,4,"rgba(0,0,0,0.55)","rgba(190,150,100,0.12)");
  S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(g.fx0+264,fy+52,7,20);
  S.fillStyle="rgba(200,158,104,0.55)";S.fillRect(g.fx0+266,fy+50,4,20);
  S.fillStyle="rgba(120,96,70,0.45)";S.fillRect(g.fx0+166,fy+104,7,10);S.fillRect(g.fx0+166,fy+96,4,6);
  /* The asset plate was riveted at fy+6 and then painted over by the door
     drawn two calls later — it had never been visible. On the door, where a
     shop actually rivets it. */
  assetPlate(g.fx0+230,fy+46,34,"#3a2c1c","rgba(214,190,150,0.75)");
  // and the welding lead, coiled on a hook and dropped to the deck
  cableHang(g.fx0+150,fy+6,g.fx0+128,fy+40,26,"rgba(10,8,6,0.9)",4);
  cableHang(g.fx0+128,fy+40,g.fx0+150,g.by-8,34,"rgba(10,8,6,0.9)",4);

  // ON the surface, in the surface's own perspective
  var vp=deckStand(g,0.20,0.62,0), s2=vp.s;
  // vise: base, fixed jaw, sliding jaw, screw, handle
  S.fillStyle="rgba(0,0,0,0.45)";S.beginPath();S.ellipse(vp.x+14*s2,vp.y+1,34*s2,5*s2,0,0,7);S.fill();
  /* R3 — the vise, dark. It was mid-grey on a dark top with a hot glow next
     to it, which at this size is a pale blob: three values too close together
     and none of them dark enough to hold a shape. Cast iron is nearly black
     and reads by its ARRIS — one bright line per facet where the lamp catches
     it. */
  plate(S,[[vp.x-8*s2,vp.y-9*s2],[vp.x+56*s2,vp.y-9*s2],[vp.x+56*s2,vp.y],[vp.x-8*s2,vp.y]],"#1d242e","#0e1319","#39434f");
  plate(S,[[vp.x,vp.y-30*s2],[vp.x+12*s2,vp.y-30*s2],[vp.x+12*s2,vp.y-9*s2],[vp.x,vp.y-9*s2]],"#232b35","#12171e","#4a5765");
  S.fillStyle="rgba(190,206,228,0.30)";S.fillRect(vp.x,vp.y-30*s2,12*s2,1.4);
  plate(S,[[vp.x+30*s2,vp.y-30*s2],[vp.x+42*s2,vp.y-30*s2],[vp.x+42*s2,vp.y-9*s2],[vp.x+30*s2,vp.y-9*s2]],"#1f2731","#101620","#44505e");
  S.fillStyle="rgba(190,206,228,0.26)";S.fillRect(vp.x+30*s2,vp.y-30*s2,12*s2,1.4);
  S.fillStyle="rgba(190,206,228,0.18)";S.fillRect(vp.x-8*s2,vp.y-9*s2,64*s2,1.2);
  S.strokeStyle="#5a6674";S.lineWidth=3.5;S.beginPath();S.moveTo(vp.x+42*s2,vp.y-20*s2);S.lineTo(vp.x+58*s2,vp.y-20*s2);S.stroke();
  S.fillStyle="#6b7788";S.beginPath();S.arc(vp.x+59*s2,vp.y-20*s2,4*s2,0,7);S.fill();
  rivet(S,vp.x-4*s2,vp.y-4*s2,"rgba(160,180,210,0.45)");rivet(S,vp.x+52*s2,vp.y-4*s2,"rgba(160,180,210,0.45)");
  /* The piece in the jaws is the state: clamped and hot at the end the unit
     has been working, or out of the jaws entirely. */
  if(st==="working"){
    plate(S,[[vp.x+12*s2,vp.y-42*s2],[vp.x+30*s2,vp.y-42*s2],[vp.x+30*s2,vp.y-9*s2],[vp.x+12*s2,vp.y-9*s2]],"#4d5866","#2c343f","#6a7787");
    var hot=0.55+0.45*Math.abs(Math.sin(t*2.3));
    /* R2 — the heat is IN the metal, not painted over it. It was a gradient
       laid across the whole piece, and at this size that swallowed the vise:
       the jaws, the screw and the handle all disappeared into one bright
       smear. Now only the top of the stock glows, the jaws stay dark, and the
       glow is drawn to the emissive buffer alone so the compositor blooms it
       around the silhouette instead of erasing it. */
    emit(function(c){var hg=c.createLinearGradient(0,vp.y-42*s2,0,vp.y-30*s2);
      hg.addColorStop(0,"rgba(255,168,80,"+(0.85*hot)+")");hg.addColorStop(1,"rgba(255,110,40,0)");
      c.fillStyle=hg;c.fillRect(vp.x+12*s2,vp.y-42*s2,18*s2,12*s2);});
    S.fillStyle="rgba(255,196,120,"+(0.5*hot)+")";S.fillRect(vp.x+12*s2,vp.y-42*s2,18*s2,2);
    spill(vp.x+21*s2,vp.y-38*s2,32,17,[255,150,60],0.10*hot);
    scorch(vp.x+21*s2,vp.y-4,30,6,0.55);
    /* L9 — the work sheds. Hot stock spits: three flecks arc off the piece
       and die on the steel, each on its own phase, drawn to the emissive
       buffer so they bloom the way the sparks behind the station do. Motion
       stays out of reduced mode. */
    if(!reduced)for(var fk=0;fk<3;fk++){var fp=(t*(0.9+fk*0.13)+fk*0.41)%1;
      var fu=0.24+fk*0.09+0.10*fp, fv=0.62-0.34*fp+0.3*fp*fp;
      var fpt=deckAt(g,fu,Math.max(0.06,fv)), fa=(1-fp)*(1-fp)*hot*0.8;
      emit(function(c){c.fillStyle="rgba(255,196,110,"+fa+")";c.fillRect(fpt.x,fpt.y-(28*fp*(1-fp)),1.8,1.8);});}
  }
  /* A surface this size has to look worked at. A parts tray with fasteners in
     it, offcuts, and the scorch ring where hot stock has been set down and
     picked up again. */
  var oc=deckAt(g,0.50,0.22);
  scorch(oc.x+30,oc.y+6,26,7,0.5);
  S.fillStyle="#2b3540";S.fillRect(oc.x,oc.y-3,44,5);
  S.fillStyle="rgba(180,196,218,0.16)";S.fillRect(oc.x,oc.y-3,44,1);
  S.fillStyle="#232c36";S.fillRect(oc.x+6,oc.y-7,30,4);
  var tr=deckAt(g,0.66,0.52);
  plate(S,[[tr.x-24,tr.y-7],[tr.x+24,tr.y-7],[tr.x+21,tr.y+2],[tr.x-21,tr.y+2]],"#232c37","#12181f","#3a4553");
  for(var n=0;n<5;n++){S.fillStyle="rgba(150,168,190,"+(0.3+0.12*(n%2))+")";S.fillRect(tr.x-16+n*8,tr.y-4,4,2.5);}

  // task monitor, on a post at the back right of the surface
  var mp=deckStand(g,0.80,0.28,0), ms=mp.s, mw=54*ms, mh=36*ms, my=mp.y-58*ms;
  S.fillStyle="#161d29";S.fillRect(mp.x-3*ms,my+mh,6*ms,mp.y-(my+mh));
  S.fillStyle="#1e2836";S.fillRect(mp.x-9*ms,mp.y-4*ms,18*ms,5*ms);
  rivet(S,mp.x-5*ms,mp.y-2*ms,"rgba(150,175,210,0.4)");rivet(S,mp.x+4*ms,mp.y-2*ms,"rgba(150,175,210,0.4)");
  plate(S,[[mp.x-mw/2,my],[mp.x+mw/2,my],[mp.x+mw/2,my+mh],[mp.x-mw/2,my+mh]],"#12202e","#0a1420","#22304a");
  var mcol=st==="working"?[247,189,78]:st==="offline"?[120,60,60]:[90,150,210];
  emit(function(c){
    c.fillStyle=rgba(mcol[0],mcol[1],mcol[2],on?0.42:0.26);c.fillRect(mp.x-mw/2+5,my+5,mw-10,mh-10);
    c.fillStyle=rgba(mcol[0],mcol[1],mcol[2],on?0.62:0.3);
    var sw=[0.62,0.4,0.5];for(var l=0;l<3;l++)c.fillRect(mp.x-mw/2+8,my+9+l*7,(mw-16)*sw[l],2);});
  if(on){spill(mp.x,my+mh/2,52,30,mcol,0.07);spill(mp.x,mp.y+4,44,11,mcol,0.05);}
}

/* REVIEWER — an inspection bench: a void under the glass, so its silhouette is
   the one with a hole in it. */
function inspectBench(t,lit,st){
  var off=st==="offline";
  deckGround({lit:lit,st:st,glow:[150,196,245]});
  var g=deckBody({lit:lit,lean:0,key:[196,232,255],toe:"#3d4a5c",
    topBack:"#333d49",topFront:"#28303a",face:"#121822",foot:"#090e15",side:"#0c121a"});
  /* Glass: one specular streak at the lamp's angle across the top face. */
  var gs=S.createLinearGradient(g.bx0+40,g.ty,g.bx0+180,g.tf);
  gs.addColorStop(0,"rgba(210,238,255,0)");gs.addColorStop(0.5,"rgba(210,238,255,"+(0.10+0.10*lit)+")");
  gs.addColorStop(1,"rgba(210,238,255,0)");
  S.fillStyle=gs;poly(S,[[g.bx0,g.ty],[g.bx1,g.ty],[g.fx1,g.tf],[g.fx0,g.tf]]);S.fill();
  wornEdge(g.fx0,g.tf-2,DECK.fw,"rgba(200,224,248,0.15)",5.7);
  /* L5 — the top is a MATERIAL again: this one is edge-lit glass. What says
     glass is not the streak (a polished steel top would streak too) but the
     EDGE — light piped through the slab escapes at the perimeter, so a thin
     cool line runs round the inset rim and glows faintly, held down by four
     corner clips. */
  emit(function(c){c.strokeStyle="rgba(170,224,255,"+(0.10+0.10*lit)+")";c.lineWidth=1.4;
    var e0=deckAt(g,0.015,0.08),e1=deckAt(g,0.985,0.08),e2=deckAt(g,0.985,0.94),e3=deckAt(g,0.015,0.94);
    c.beginPath();c.moveTo(e0.x,e0.y);c.lineTo(e1.x,e1.y);c.lineTo(e2.x,e2.y);c.lineTo(e3.x,e3.y);c.closePath();c.stroke();});
  [[0.015,0.08],[0.985,0.08],[0.015,0.94],[0.985,0.94]].forEach(function(cp){
    var p3=deckAt(g,cp[0],cp[1]);
    S.fillStyle="#2b3746";S.fillRect(p3.x-3,p3.y-2,6,4);
    S.fillStyle="rgba(200,230,255,0.35)";S.fillRect(p3.x-3,p3.y-2,6,1);});

  // front face: drawer bank right, open shelf left — the void
  var fy=g.tf+8;
  S.fillStyle="rgba(0,0,0,0.62)";S.fillRect(g.fx0+16,fy+4,124,58);
  for(var p=0;p<5;p++){var py=fy+52-p*5;
    S.fillStyle="rgba(0,0,0,0.4)";S.fillRect(g.fx0+34+p,py+3,84,2);
    S.fillStyle=p%2?"#9aa5b4":"#8a95a4";S.fillRect(g.fx0+34+p,py,84,3);
    S.fillStyle="rgba(226,236,248,0.5)";S.fillRect(g.fx0+34+p,py,84,1);}
  S.fillStyle="#1a2430";S.fillRect(g.fx0+14,fy+62,128,7);
  S.fillStyle="rgba(160,190,225,0.10)";S.fillRect(g.fx0+14,fy+62,128,1);
  /* L3 — the face re-cut for the height. The shelf and the drawer bank both
     stopped 60px above the toe. The lab keeps its archive low: a second bay
     under the paper shelf, box files stood in it shoulder to shoulder, the
     spine labels catching what light reaches down there. */
  S.fillStyle="rgba(0,0,0,0.62)";S.fillRect(g.fx0+16,fy+72,124,40);
  for(var bf=0;bf<6;bf++){var bx2=g.fx0+22+bf*19,bh2=[33,36,31,35,32,34][bf];
    S.fillStyle=["#232f3d","#1e2937","#26313f","#202b39","#242e3c","#1f2a38"][bf];
    S.fillRect(bx2,fy+112-bh2,16,bh2);
    S.fillStyle="rgba(150,180,215,0.16)";S.fillRect(bx2,fy+112-bh2,16,1);
    S.fillStyle=bf===2?"rgba(95,206,155,0.4)":bf===4?"rgba(230,180,100,0.35)":"rgba(170,200,235,0.28)";
    S.fillRect(bx2+3,fy+112-bh2+5,10,2);}
  S.fillStyle="#1a2430";S.fillRect(g.fx0+14,fy+112,128,6);
  S.fillStyle="rgba(160,190,225,0.08)";S.fillRect(g.fx0+14,fy+112,128,1);
  // a divider in the void, and a label holder on the top drawer
  S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(g.fx0+92,fy+6,3,54);
  S.fillStyle="rgba(150,180,215,0.10)";S.fillRect(g.fx0+95,fy+6,1,54);
  S.fillStyle="#0f151d";S.fillRect(g.fx0+172,fy+5,26,9);
  S.fillStyle="rgba(200,224,248,0.45)";S.fillRect(g.fx0+175,fy+8,20,1.5);
  // the lamp's flex, run down the back corner of the carcass
  cableHang(g.fx1-26,g.tf+4,g.fx1-14,g.by-14,30,"rgba(8,12,18,0.9)",3);
  for(var d=0;d<3;d++)drawerFace(g.fx0+164,fy+d*24,122,22,"#1c2532","#3b4a5e","rgba(180,205,235,0.5)");
  // and one deep file drawer at the bottom, where the weight belongs
  drawerFace(g.fx0+164,fy+72,122,38,"#182130","#33415a","rgba(180,205,235,0.45)");
  assetPlate(g.fx0+176,fy+114,34,"#20293a","rgba(190,214,240,0.75)");

  // the lens arm, clamped to the back right of the surface
  var lp=deckStand(g,0.78,0.30,0), ls=lp.s;
  plate(S,[[lp.x-11*ls,lp.y-12*ls],[lp.x+11*ls,lp.y-12*ls],[lp.x+11*ls,lp.y],[lp.x-11*ls,lp.y]],"#2b3746","#161e28","#3d4c5f");
  rivet(S,lp.x-6*ls,lp.y-6*ls,"rgba(180,205,235,0.5)");rivet(S,lp.x+5*ls,lp.y-6*ls,"rgba(180,205,235,0.5)");
  var hx=lp.x-52*ls, hy=lp.y-64*ls;
  S.strokeStyle="#3a465e";S.lineWidth=3;S.beginPath();
  S.moveTo(lp.x,lp.y-11*ls);S.lineTo(lp.x-6*ls,lp.y-46*ls);S.lineTo(hx,hy);S.stroke();
  S.fillStyle="#4a5a70";S.beginPath();S.arc(lp.x-6*ls,lp.y-46*ls,3.4*ls,0,7);S.fill();
  S.fillStyle="#141b26";S.beginPath();S.ellipse(hx,hy,13*ls,7*ls,0,0,7);S.fill();
  S.fillStyle="#1e2836";S.fillRect(hx-13*ls,hy-1,26*ls,6*ls);
  S.fillStyle="#0c1119";S.beginPath();S.ellipse(hx,hy+5*ls,13*ls,5*ls,0,0,7);S.fill();
  if(!off){
    /* L9 — the lens BREATHES: an inspection lamp on a live bench is never at
       constant power, and the slow swell is the only cue at this size that
       the instrument is on rather than painted on. */
    var lb=reduced?1:0.8+0.2*Math.sin(t*1.3);
    S.fillStyle="rgba(224,244,255,"+(0.65+0.20*lb)+")";S.beginPath();S.ellipse(hx,hy+5*ls,8*ls,3.4*ls,0,0,7);S.fill();
    spill(hx,hy+7*ls,20,17,[196,232,255],0.05+0.04*lb);
    /* ... and when there is a specimen under it, the read head tracks: one
       narrow specular sliver walking the glass, left to right and back. */
    if(!reduced&&st==="working"){var swu=0.5+0.42*Math.sin(t*0.5);
      var wa=deckAt(g,swu,0.12),wb=deckAt(g,swu+0.04,0.88);
      var sg2=S.createLinearGradient(wa.x-8,0,wb.x+8,0);
      sg2.addColorStop(0,"rgba(210,238,255,0)");sg2.addColorStop(0.5,"rgba(210,238,255,0.06)");sg2.addColorStop(1,"rgba(210,238,255,0)");
      S.fillStyle=sg2;poly(S,[[wa.x-8,wa.y],[wa.x+16,wa.y],[wb.x+16,wb.y],[wb.x-8,wb.y]]);S.fill();}
  }
  /* The specimen is only under the lamp when there is something to look at. */
  var sp=deckAt(g,0.60,0.58);
  S.fillStyle="rgba(0,0,0,0.4)";S.beginPath();S.ellipse(sp.x,sp.y+2,22,4.5,0,0,7);S.fill();
  plate(S,[[sp.x-20,sp.y-6],[sp.x+20,sp.y-6],[sp.x+17,sp.y+2],[sp.x-17,sp.y+2]],"#1b2634","#0d141d","#31415a");
  if(st==="working"){
    emit(function(c){
      c.fillStyle="rgba(150,214,255,0.5)";c.fillRect(sp.x-13,sp.y-4,26,3);
      c.fillStyle="rgba(90,210,130,0.7)";c.fillRect(sp.x-12,sp.y-4,8,3);
      c.fillStyle="rgba(230,100,100,0.7)";c.fillRect(sp.x+3,sp.y-4,5,3);});
    if(!off)spill(sp.x,sp.y-2,26,8,[196,232,255],0.07);
  }
  // a slide tray at the back of the glass, and two markers
  var tv=deckAt(g,0.36,0.22);
  plate(S,[[tv.x-30,tv.y-6],[tv.x+30,tv.y-6],[tv.x+27,tv.y+2],[tv.x-27,tv.y+2]],"#1b2532","#0e141c","#324457");
  for(var sl=0;sl<6;sl++){S.fillStyle=sl%2?"rgba(170,205,235,0.35)":"rgba(140,175,210,0.25)";
    S.fillRect(tv.x-24+sl*9,tv.y-4,6,5);}
  var mk=deckAt(g,0.86,0.44);
  S.fillStyle="#2a3442";S.fillRect(mk.x-14,mk.y-4,26,4);
  S.fillStyle="rgba(95,206,155,0.7)";S.fillRect(mk.x+10,mk.y-4,4,4);
  S.fillStyle="#2a3442";S.fillRect(mk.x-12,mk.y-9,26,4);
  S.fillStyle="rgba(230,100,100,0.7)";S.fillRect(mk.x+12,mk.y-9,4,4);
  // the stamp block, and what it last stamped
  var stp=deckAt(g,0.16,0.42);
  plate(S,[[stp.x-16,stp.y-16],[stp.x+16,stp.y-16],[stp.x+16,stp.y],[stp.x-16,stp.y]],"#2a3442","#151d26","#3a4759");
  S.fillStyle=off?"#3a2424":(st==="working"?"#f7bd4e":"#5fce9b");S.fillRect(stp.x-10,stp.y-11,20,5);
  if(!off)spill(stp.x,stp.y-8,20,9,st==="working"?[247,189,78]:[95,206,155],0.09);
  S.fillStyle="#151d26";S.fillRect(stp.x-4,stp.y-24,8,8);
}

/* TRIAGE — a plotting console. The front face LEANS back, so its silhouette is
   the wedge, and the top face is the chart itself: we are looking down at the
   thing the room exists to read. */
function plotTable(t,lit,st){
  var off=st==="offline";
  deckGround({lit:lit,st:st,glow:[168,150,255]});
  var g=deckBody({lit:lit,lean:26,key:[190,180,255],toe:"#39406a",
    topBack:"#111925",topFront:"#0c141e",face:"#101623",foot:"#080b13",side:"#0a0f18"});
  /* The chart, drawn IN the top face's perspective: lines that converge with
     the surface instead of lying flat across it. */
  S.save();
  poly(S,[[g.bx0+3,g.ty+2],[g.bx1-3,g.ty+2],[g.fx1-3,g.tf-2],[g.fx0+3,g.tf-2]]);S.clip();
  S.fillStyle="#070d16";S.fillRect(g.fx0,g.ty,DECK.fw,DECK.td+4);
  S.strokeStyle="rgba(80,120,170,0.34)";S.lineWidth=1;
  for(var c3=0;c3<=8;c3++){var u=c3/8,a=deckAt(g,u,0),b=deckAt(g,u,1);
    S.beginPath();S.moveTo(a.x,a.y);S.lineTo(b.x,b.y);S.stroke();}
  for(var r3=1;r3<3;r3++){var v=r3/3,l=deckAt(g,0,v),r=deckAt(g,1,v);
    S.beginPath();S.moveTo(l.x,l.y);S.lineTo(r.x,r.y);S.stroke();}
  if(!off)emit(function(c){c.save();c.globalCompositeOperation="lighter";
    /* Traffic. Running when work is being dispatched, crawling when it is
       not — and each blip drawn at the surface point it has reached, so they
       run along the chart in perspective rather than across the screen. */
    var sp3=st==="working"?0.32:0.08, amp=st==="working"?0.45:0.18, base=st==="working"?0.4:0.18;
    for(var b3=0;b3<6;b3++){var ph=(t*sp3+b3*0.17)%1, v2=((b3%3)+0.5)/3.2;
      var pt=deckAt(g,ph,v2), sz=2+2*v2;
      c.fillStyle="rgba(150,200,255,"+(base+amp*Math.sin(t*3+b3))+")";c.fillRect(pt.x,pt.y,sz,sz*0.8);
      if(st==="working"){c.fillStyle="rgba(150,200,255,0.14)";c.fillRect(pt.x-13,pt.y+sz*0.2,13,sz*0.5);}}
    c.restore();});
  /* R3 — a route. The chart was a grid with dots on it; what a dispatch table
     shows is a PATH being taken, so one lane is lit end to end and the blips
     run down it. The three sector ticks give the grid a scale. */
  if(!off){var la=deckAt(g,0.06,0.44),lb=deckAt(g,0.94,0.44);
    S.strokeStyle="rgba(140,180,255,0.30)";S.lineWidth=2.2;
    S.beginPath();S.moveTo(la.x,la.y);S.lineTo(lb.x,lb.y);S.stroke();
    emit(function(c){c.save();c.globalCompositeOperation="lighter";
      c.strokeStyle="rgba(150,200,255,0.16)";c.lineWidth=4;
      c.beginPath();c.moveTo(la.x,la.y);c.lineTo(lb.x,lb.y);c.stroke();c.restore();});}
  for(var tk=1;tk<4;tk++){var tp=deckAt(g,tk/4,0.86);
    S.fillStyle="rgba(170,195,240,0.35)";S.fillRect(tp.x-1,tp.y-5,2,5);}
  // acrylic: one shallow band across the surface
  var ac=S.createLinearGradient(g.bx0+50,g.ty,g.bx0+200,g.tf);
  ac.addColorStop(0,"rgba(214,224,255,0)");ac.addColorStop(0.45,"rgba(214,224,255,"+(0.07+0.06*lit)+")");
  ac.addColorStop(1,"rgba(214,224,255,0)");
  S.fillStyle=ac;S.fillRect(g.fx0,g.ty,DECK.fw,DECK.td+4);
  S.restore();
  /* L5 — the top is a MATERIAL again: an acrylic sheet over the plot, and a
     sheet is HELD — four corner brackets pinch it to the table, each an L in
     the surface's perspective with one lit edge. Without them the chart is a
     texture; with them it is a thing lying on a thing. */
  [[0.03,0.10,1],[0.97,0.10,-1],[0.03,0.90,1],[0.97,0.90,-1]].forEach(function(br){
    var p4=deckAt(g,br[0],br[1]),dx=br[2];
    S.strokeStyle="#3a4468";S.lineWidth=2.6;
    S.beginPath();S.moveTo(p4.x+dx*9,p4.y);S.lineTo(p4.x,p4.y);S.lineTo(p4.x,p4.y+(br[1]<0.5?5:-5));S.stroke();
    S.strokeStyle="rgba(190,180,255,0.30)";S.lineWidth=1;
    S.beginPath();S.moveTo(p4.x+dx*9,p4.y-1);S.lineTo(p4.x-dx,p4.y-1);S.stroke();});

  // the leaning fascia: three switches in housings, a readout, an asset plate
  var fy=g.tf+14;
  for(var s2=0;s2<3;s2++){var sx=g.fx0+40+s2*46;
    plate(S,[[sx-5,fy],[sx+22,fy],[sx+22,fy+13],[sx-5,fy+13]],"#2f3947","#171f29","#435264");
    S.fillStyle="#0b1119";S.fillRect(sx,fy+3,17,6);
    S.fillStyle=off?"#4a2a2a":(s2===1?"#f7bd4e":"#5fce9b");S.fillRect(sx+(s2===1?9:1),fy+4,7,3);
    rivet(S,sx-2,fy+2,"rgba(160,185,225,0.4)");}
  /* R2 — the fascia is a console, so it gets a console's parts: a keypad
     block, a vented bay for whatever is humming inside, and the readout. An
     angled panel with three switches on it and nothing else was a lectern. */
  louvres(g.fx0+38,fy+22,84,26,4,"rgba(0,0,0,0.5)","rgba(150,175,235,0.10)");
  for(var k=0;k<12;k++){var kx=g.fx1-206+(k%4)*15, ky=fy+2+Math.floor(k/4)*13;
    S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(kx,ky,12,10);
    S.fillStyle="#1a2231";S.fillRect(kx+1,ky+1,10,8);
    S.fillStyle="rgba(150,175,235,0.12)";S.fillRect(kx+1,ky+1,10,1);}
  plate(S,[[g.fx1-116,fy],[g.fx1-40,fy],[g.fx1-40,fy+26],[g.fx1-116,fy+26]],"#1b2331","#0d131c","#2b3646");
  /* L9 — the readout READS. Three fixed bars said "screen"; three bars whose
     lengths step while work is being dispatched say "throughput". Idle they
     settle, offline they dim, reduced motion pins them. */
  emit(function(c){var col=off?[120,60,60]:[150,180,255];
    for(var l=0;l<3;l++){var bw2=[46,30,38][l];
      if(!reduced&&!off&&st==="working")bw2=bw2*(0.62+0.38*Math.abs(Math.sin(t*(1.7+l*0.53)+l*2.1)));
      c.fillStyle=rgba(col[0],col[1],col[2],off?0.22:0.5);
      c.fillRect(g.fx1-110,fy+5+l*7,bw2,2);}});
  assetPlate(g.fx1-104,fy+34,34,"#232c3d","rgba(198,190,255,0.75)");
  /* L3 — the face re-cut for the height. Below the keypad row the fascia ran
     out of console 60px early. A console's lower third is service access: one
     wide panel on quarter-turn latches, a vent to let whatever is routing in
     there breathe, and the loom dropping out of the readout into the floor. */
  var ax0=g.fx0+44,ax1=g.fx1-44,ay=fy+56,ah=52;
  S.fillStyle="rgba(0,0,0,0.5)";S.fillRect(ax0-2,ay-2,ax1-ax0+4,ah+4);
  S.fillStyle="#131a2a";S.fillRect(ax0,ay,ax1-ax0,ah);
  S.fillStyle="rgba(150,175,235,0.10)";S.fillRect(ax0,ay,ax1-ax0,1);
  louvres(ax0+14,ay+14,ax1-ax0-98,24,4,"rgba(0,0,0,0.5)","rgba(150,175,235,0.08)");
  [[ax0+7,ay+7],[ax1-7,ay+7],[ax0+7,ay+ah-7],[ax1-7,ay+ah-7]].forEach(function(lt){
    S.fillStyle="#0b1119";S.beginPath();S.arc(lt[0],lt[1],3.4,0,7);S.fill();
    S.strokeStyle="rgba(170,190,240,0.35)";S.lineWidth=1.2;
    S.beginPath();S.moveTo(lt[0]-2.4,lt[1]);S.lineTo(lt[0]+2.4,lt[1]);S.stroke();});
  S.fillStyle="rgba(150,175,235,0.14)";S.fillRect(ax1-72,ay+16,52,2);S.fillRect(ax1-72,ay+26,38,2);
  cableHang(g.fx1-78,fy+28,g.fx1-96,g.by-10,24,"rgba(8,10,18,0.9)",3.5);
  hazard(g.fx0+22,g.by-14,86,4,0.3);
}

/* ===================== SCENE ENV ===================== */
function drawTarget(t,dt){
  var offl=STATE==="offline", work=STATE==="working";
  stepLamp(t,dt,!offl);var lit=lamp.lit*(work?1:0.8);
  S.setTransform(1,0,0,1,0,0);S.globalAlpha=1;S.globalCompositeOperation="source-over";S.filter="none";
  G.setTransform(1,0,0,1,0,0);G.globalAlpha=1;G.globalCompositeOperation="source-over";G.filter="none";
  S.clearRect(0,0,DW,DH);G.clearRect(0,0,DW,DH);
  S.fillStyle="#02040a";S.fillRect(0,0,DW,DH);
  var cg=S.createLinearGradient(0,0,0,DH);cg.addColorStop(0,"rgba(18,34,54,0.30)");cg.addColorStop(.5,"rgba(6,12,22,0)");S.fillStyle=cg;S.fillRect(0,0,DW,DH);

  drawDeepRacks(t);
  drawBackWall(t,lit);
  floorPlane(t,lit,STATE);   // owns everything below FLOORY; must run after the wall
  rightTower(t);
  drawRedBeacon(t,offl?1:0.14);
  // wall attachments FIRST, so the volumetric light reads in front of them
  /* Wall attachments, each one filling a bay named in BAYS. The six added in
     loop 13 are listed second in each room so the older props keep their
     stacking order — none of the new ones overlaps anything, so the order is
     bookkeeping rather than occlusion. */
  if(ROOM==="builder"){ floorHazard(); crane(t); fabBay(t,lit,STATE); pegboard(t,lit);
    gasRack(t,lit,STATE); firePoint(t,lit,STATE); }
  else if(ROOM==="reviewer"){ diffWall(t,STATE); checklistBoard();
    calChart(t,lit,STATE); sampleArchive(t,lit,STATE); }
  else { kanban(t,STATE); radar(t,STATE); switchboard(t,STATE);
    tubeStation(t,lit,STATE); dutyBoard(t,lit,STATE); }
  wallKey(lit,ROOM);                // the lamp reaching the wall AND what is bolted to it
  pilasters(t,lit);                 // where the wall stops, and why
  roofTruss(t,lit);                 // mid plane: in front of the wall, behind the unit
  cableSwag(lit);                   // hangs from the truss; the room's only diagonal
  drawLampCone(t,lit,!offl,ROOM);   // light between wall attachments and robot
  stepSparks(dt);
  /* Depth. Every unit hangs or stands behind the near-plane station, which
     crosses its shins — or, for kimi, its fists and cowl. The special case
     this slot used to carry is gone, and the worry it answered went with the
     drone: the old shell on the floor vanished behind the worktop entirely,
     but the JUGGERNAUT's knuckle-rest keeps head, pauldrons and furnace
     above the bench line, so it draws where every other unit draws. */
  drawRobot(t);
  if(ROOM==="builder"){ conveyor(t,STATE); crateBig(206,558);crateBig(182,588); }
  /* The in-tray. A review lab that is idle is a review lab with a queue on the
     desk — two flat stacks said the same thing whether anything was pending or
     not, so a third, visibly taller pile only appears when nothing is being
     reviewed. It is the room's own version of "work is waiting". */
  else if(ROOM==="reviewer"){ verdictTower(t,STATE); fileCabinet(1040); fileCabinet(1078); docStack(690); docStack(720);
    if(STATE==="idle")for(var ip=0;ip<11;ip++){S.fillStyle=ip%2?"#c3cdda":"#a6b1c0";S.fillRect(752-(ip%2),FLOORY-6-ip*4,26,4);} }
  else { phoneBank(1042,t,STATE); fileCabinet(1086); docStack(700); }
  drawSparks();
  drawFloorFog(t);
  drawSteam(t);
  /* The deck station, in the NEAR plane. It is drawn here — after the unit,
     after the sparks, after the fog and the steam — because it stands between
     all of them and the camera, on the 108px of deck in front of the unit's
     feet that nothing used to stand on. Drawing it with the other floor props
     was the bug: props in that list share the unit's depth, and something at
     the unit's depth cannot get in front of it. */
  deckStation(t,lit,STATE);
  nearSideProp(t,lit,STATE);        // L6 — the plane's second citizen
  nearMotes(t,STATE);               // L20 — the air in front of the subject
  roomForeground(t,STATE);
  nearEdge();                       // near plane, out of focus
  drawForeground();

  C.setTransform(1,0,0,1,0,0);C.globalAlpha=1;C.globalCompositeOperation="source-over";C.filter="none";C.clearRect(0,0,DW,DH);
  C.drawImage(scene,0,0);
  C.globalCompositeOperation="lighter";
  C.filter="blur(6px)";C.globalAlpha=0.42;C.drawImage(glow,0,0);
  C.filter="blur(16px)";C.globalAlpha=0.64;C.drawImage(glow,0,0);
  C.filter="blur(34px)";C.globalAlpha=0.46;C.drawImage(glow,0,0);
  C.globalCompositeOperation="source-over";C.filter="none";C.globalAlpha=1;
  C.globalCompositeOperation="overlay";C.globalAlpha=0.05;var nx=-Math.random()*40,ny=-Math.random()*40;
  for(var gx=nx;gx<DW;gx+=220)for(var gy=ny;gy<DH;gy+=220)C.drawImage(noise,gx,gy);
  C.globalCompositeOperation="source-over";C.globalAlpha=0.05;C.fillStyle="#000";for(var sl=0;sl<DH;sl+=3)C.fillRect(0,sl,DW,1);C.globalAlpha=1;
  /* The vignette was centred at 0.46 of the frame — nearer the geometric
     centre of the canvas than to the thing the picture is of. The unit stands
     at ROBOX/DW = 0.367, and a vignette's whole job is to say where to look.
     Moved onto the subject, which costs the right-hand props a little falloff
     and is the correct trade: they are context, and the unit is not. */
  var vg=C.createRadialGradient(DW*0.40,DH*0.46,DH*0.30,DW*0.44,DH*0.52,DH*0.92);vg.addColorStop(0,"rgba(0,0,0,0)");vg.addColorStop(1,"rgba(0,0,0,0.80)");C.fillStyle=vg;C.fillRect(0,0,DW,DH);
  /* Room grade. Every prop, wall and floor in all three rooms was tinted one
     at a time, by hand, and they still came out of the compositor sharing the
     same neutral blue-black — because a grade is a property of the WHOLE
     frame, and nothing was applying one. Three rooms lit by the same lamp
     should still not photograph the same.
     Two passes: a lift into the shadows, which is what actually carries the
     colour of a dark scene, and a screen over the highlights so the key light
     picks up temperature. Deliberately small — this is a grade, not a filter,
     and it has to survive being looked at 36 times on one page. */
  var GR=ROOM==="builder"?[255,176,96]:ROOM==="reviewer"?[122,196,255]:[186,150,255];
  C.save();
  C.globalCompositeOperation="lighter";C.globalAlpha=0.030;
  C.fillStyle=rgba(GR[0],GR[1],GR[2],1);C.fillRect(0,0,DW,DH);
  C.globalCompositeOperation="overlay";C.globalAlpha=0.055;
  var lift=C.createLinearGradient(0,0,0,DH);
  lift.addColorStop(0,rgba(GR[0],GR[1],GR[2],1));
  lift.addColorStop(0.62,rgba(GR[0]*0.55,GR[1]*0.55,GR[2]*0.62,1));
  lift.addColorStop(1,rgba(GR[0]*0.3,GR[1]*0.3,GR[2]*0.4,1));
  C.fillStyle=lift;C.fillRect(0,0,DW,DH);
  C.restore();
}
/* ---- borrowing the room renderer -------------------------------------------
   drawTarget draws whatever the globals currently name, and writes module
   state on the way through: the lamp's flicker, the weld spark pool, and the
   anchors the unit reported. Two callers now render rooms out of band — the
   god-view cell, every few seconds per unit, and the asset map, 36 times on
   one page — and both need the same two guarantees. A tile must not depend on
   how many frames the previous caller happened to run, or the grid stops being
   comparable and a diff stops meaning anything. And the caller's own animation
   has to be exactly where it left it afterwards, or one view's frame leaks
   into another's.

   The dev hook used to do the first and only half of the second: it reset the
   lamp and the sparks and left them reset, and never saved the footprints at
   all. That was invisible while the whiteboard was the only caller — which is
   exactly the kind of thing that stops being invisible the day a second one
   arrives. Both halves live here now, so the two callers cannot disagree about
   the contract by drifting apart. */
function borrowRoom(o,fn){
  var sa=AGENT,sr=ROOM,ss=STATE,sb=BOX,sl=lastHand,sf=lastFeet,san=lastAnchors,
      sll=lamp.lit,sld=lamp.drop,ssp=sparks.slice();
  AGENT=o.agent;ROOM=o.room;STATE=o.state;BOX=o.box||(o.agent+"-"+o.room);
  /* The lamp and the sparks are the only two things that carry across frames,
     so both are reset and then warmed a FIXED number of frames. */
  lamp.lit=1;lamp.drop=0;sparks.length=0;
  var t=o.t||0,dt=1/60,warm=o.warm===undefined?12:o.warm;
  for(var w=warm;w>0;w--)drawTarget(t-w*dt,dt);
  drawTarget(t,dt);
  var out=fn?fn():null;
  AGENT=sa;ROOM=sr;STATE=ss;BOX=sb;lastHand=sl;lastFeet=sf;lastAnchors=san;
  lamp.lit=sll;lamp.drop=sld;sparks.length=0;
  for(var i=0;i<ssp.length;i++)sparks.push(ssp[i]);
  return out;
}

function drawDeepRacks(t){
  var defs=[[120,.34,.72],[250,.5,.5],[1060,.32,.75],[1160,.55,.42],[985,.42,.6]];
  defs.forEach(function(d,k){var x=d[0],sc=d[1],fog=d[2],w=120*sc,h=420*sc,y=FLOORY-h+40;
    S.fillStyle=rgba(8,14,22,1-fog*0.4);rr(S,x,y,w,h,4);S.fill();
    S.fillStyle=rgba(20,30,44,0.5*(1-fog));rr(S,x,y,w,6,3);S.fill();
    for(var u=0;u<14;u++){var uy=y+18+u*(h-30)/14;S.fillStyle=rgba(10,16,24,1-fog*0.3);S.fillRect(x+6,uy,w-12,(h-30)/14-3);
      if((u+k)%3===0){var on=(Math.sin(t*2.2+u+k)>0.35);var col=[[95,214,155],[95,180,255],[255,80,70],[247,189,78]][(u+k)%4];var a=(on?0.62:0.12)*(1-fog*0.6);
        emit(function(cx){cx.fillStyle=rgba(col[0],col[1],col[2],a);cx.fillRect(x+w-14,uy+2,4,4);});}}
    S.fillStyle=rgba(6,12,22,fog*0.85);rr(S,x-4,y-4,w+8,h+8,6);S.fill();});
  var fz=S.createLinearGradient(0,FLOORY-360,0,FLOORY);fz.addColorStop(0,"rgba(20,36,58,0)");fz.addColorStop(1,"rgba(24,42,66,0.10)");S.fillStyle=fz;S.fillRect(0,FLOORY-360,DW,360);
}
function drawBackWall(t,lit){
  var wx=250,ww=760,wy=150,wh=FLOORY-150;
  var wallg=S.createLinearGradient(0,wy,0,FLOORY);wallg.addColorStop(0,"#0a1019");wallg.addColorStop(1,"#05080e");S.fillStyle=wallg;S.fillRect(wx,wy,ww,wh);
  S.strokeStyle="rgba(30,44,64,0.25)";S.lineWidth=1;for(var px=wx+80;px<wx+ww;px+=120){S.beginPath();S.moveTo(px,wy);S.lineTo(px,FLOORY);S.stroke();}
  S.beginPath();S.moveTo(wx,wy+150);S.lineTo(wx+ww,wy+150);S.stroke();
  /* Per-room wall surface. The three rooms shared one wall with a different
     word painted on it, which is most of why they read as the same room three
     times: the wall is the largest object on screen and it was saying nothing.
     All of it lives right of x=660, the dead zone every room had between its
     props and the tower. */
  S.save();
  if(ROOM==="builder"){
    // bolted steel plate: horizontal seams, rivet rows, and a warning placard
    for(var py2=wy+52;py2<FLOORY-24;py2+=76){
      S.strokeStyle="rgba(44,58,80,0.4)";S.lineWidth=1;S.beginPath();S.moveTo(wx,py2);S.lineTo(wx+ww,py2);S.stroke();
      S.fillStyle="rgba(84,104,136,0.2)";for(var rx2=wx+18;rx2<wx+ww;rx2+=54)S.fillRect(rx2,py2-3,2,2);
    }
    var bpx=812,bpy=318;                                     // hazard placard
    wallShadow(bpx,bpy,96,64);
    plate(S,[[bpx,bpy],[bpx+96,bpy],[bpx+96,bpy+64],[bpx,bpy+64]],"#2b2411","#12100a","#4a3f1c");
    S.save();S.globalAlpha=0.5;for(var hs=0;hs<96;hs+=16){S.fillStyle=hs%32<16?"#c9a227":"#12100a";S.beginPath();S.moveTo(bpx+hs,bpy+4);S.lineTo(bpx+hs+8,bpy+4);S.lineTo(bpx+hs+16,bpy+16);S.lineTo(bpx+hs+8,bpy+16);S.closePath();S.fill();}S.restore();
    S.fillStyle="rgba(201,162,39,0.30)";S.fillRect(bpx+12,bpy+28,72,4);S.fillRect(bpx+12,bpy+38,54,4);S.fillRect(bpx+12,bpy+48,64,4);
    /* Grime, running down from every fixture. A workshop wall stains under
        whatever is bolted to it — the plate seams, the placard, the conduit
        brackets — and a perfectly clean one is the giveaway that this is
        geometry rather than a place where work happens. */
    S.save();
    [[818,382,54,120],[706,272,16,236],[560,254,40,70],[318,220,30,180]].forEach(function(st2){
      var sg3=S.createLinearGradient(0,st2[1],0,st2[1]+st2[3]);
      sg3.addColorStop(0,"rgba(24,18,10,0.34)");sg3.addColorStop(1,"rgba(24,18,10,0)");
      S.fillStyle=sg3;S.fillRect(st2[0],st2[1],st2[2],st2[3]);});
    S.restore();
    /* Conduit run dropping to the bay. It stays exactly where it was — x=700,
       ceiling to floor — because the prop was never the problem; it was the
       only thing on this wall with any verticality. What was wrong is that it
       crossed the room's name at full contrast. It now passes BEHIND the sign
       plate, which is drawn opaque at the end of this function, and comes out
       underneath with a stain weeping from the joint. */
    S.strokeStyle="rgba(30,42,58,0.75)";S.lineWidth=6;S.beginPath();S.moveTo(700,wy+30);S.lineTo(700,FLOORY-40);S.stroke();
    S.strokeStyle="rgba(74,92,120,0.22)";S.lineWidth=1.5;S.beginPath();S.moveTo(698,wy+30);S.lineTo(698,FLOORY-40);S.stroke();
    for(var cl=wy+70;cl<FLOORY-40;cl+=88){S.fillStyle="rgba(52,66,88,0.7)";S.fillRect(694,cl,12,7);}
  } else if(ROOM==="reviewer"){
    // modular clean-room panels: a fine seam grid, cooler and tighter than the bay
    S.strokeStyle="rgba(52,78,110,0.3)";S.lineWidth=1;
    for(var gy2=wy+46;gy2<FLOORY-16;gy2+=58){S.beginPath();S.moveTo(wx,gy2);S.lineTo(wx+ww,gy2);S.stroke();}
    for(var gx3=wx+60;gx3<wx+ww;gx3+=60){S.beginPath();S.moveTo(gx3,wy);S.lineTo(gx3,FLOORY);S.stroke();}
    S.fillStyle="rgba(120,170,220,0.05)";S.fillRect(wx,wy,ww,FLOORY-wy);
    /* Coved skirting and a cable tray. This is the room whose surfaces have to
       read as *finished* — the bay gets grime, the lab gets the detailing that
       says someone specified it: a curved wall-to-floor cove (so there is no
       corner to trap contamination) and a tray carrying the monitor runs at
       high level, rather than four screens fed by nothing. */
    var cov=S.createLinearGradient(0,FLOORY-14,0,FLOORY);
    cov.addColorStop(0,"rgba(150,185,225,0.03)");cov.addColorStop(1,"rgba(150,185,225,0.11)");
    S.fillStyle=cov;S.fillRect(wx,FLOORY-14,ww,14);
    S.fillStyle="rgba(150,185,225,0.10)";S.fillRect(wx,FLOORY-15,ww,1);
    S.fillStyle="rgba(22,32,46,0.9)";S.fillRect(wx,wy+22,ww,9);
    S.fillStyle="rgba(120,160,205,0.10)";S.fillRect(wx,wy+22,ww,1.5);
    for(var tb2=wx+30;tb2<wx+ww;tb2+=76){S.fillStyle="rgba(16,24,34,0.9)";S.fillRect(tb2,wy+31,5,12);}
    // certification plates — this lab signs what leaves it
    for(var cp=0;cp<3;cp++){var cxp2=792+cp*66,cyp2=336;
      wallShadow(cxp2,cyp2,52,70);
      plate(S,[[cxp2,cyp2],[cxp2+52,cyp2],[cxp2+52,cyp2+70],[cxp2,cyp2+70]],"#101a26","#0a1018","#22364e");
      S.fillStyle="rgba(120,190,250,0.16)";S.fillRect(cxp2+7,cyp2+9,38,3);
      for(var cl2=0;cl2<5;cl2++){S.fillStyle="rgba(150,180,210,0.10)";S.fillRect(cxp2+7,cyp2+20+cl2*8,38-(cl2%2)*12,2);}
      S.fillStyle=cp<2?"rgba(79,208,122,0.4)":"rgba(247,189,78,0.4)";S.beginPath();S.arc(cxp2+42,cyp2+60,4,0,7);S.fill();}
  } else {
    // dispatch: a cork strip of pinned work orders, and a wall clock bank
    var nb=760,nby=320,nbw=232,nbh=92;
    wallShadow(nb,nby,nbw,nbh);
    plate(S,[[nb,nby],[nb+nbw,nby],[nb+nbw,nby+nbh],[nb,nby+nbh]],"#2a2018","#150f0a","#3d2e1f");
    for(var no=0;no<9;no++){var nox=nb+10+(no%5)*44,noy=nby+10+Math.floor(no/5)*40;
      S.save();S.translate(nox+16,noy+14);S.rotate(((no*37)%9-4)*0.014);
      S.fillStyle=["rgba(214,222,232,0.34)","rgba(232,214,180,0.32)","rgba(200,220,236,0.30)"][no%3];S.fillRect(-16,-14,32,28);
      S.fillStyle="rgba(0,0,0,0.35)";for(var nl=0;nl<3;nl++)S.fillRect(-11,-8+nl*7,22-(nl%2)*8,2);
      S.fillStyle=["#c9a227","#4f9e5a","#b0563a","#5a86c9"][no%4];S.beginPath();S.arc(0,-11,2.2,0,7);S.fill();S.restore();}
    // three zone clocks — dispatch is about when, not only where
    [0,1,2].forEach(function(ci){var ccx2=690,ccy=326+ci*46;
      wallShadow(ccx2-12,ccy-12,24,24,0.8);
      S.fillStyle="#0b111a";S.beginPath();S.arc(ccx2,ccy,15,0,7);S.fill();
      S.strokeStyle="rgba(70,92,120,0.5)";S.lineWidth=1.4;S.beginPath();S.arc(ccx2,ccy,15,0,7);S.stroke();
      var ang=[1.1,3.0,5.2][ci];S.strokeStyle="rgba(160,190,220,0.42)";S.lineWidth=1.4;
      S.beginPath();S.moveTo(ccx2,ccy);S.lineTo(ccx2+Math.cos(ang)*9,ccy+Math.sin(ang)*9);S.stroke();
      S.beginPath();S.moveTo(ccx2,ccy);S.lineTo(ccx2+Math.cos(ang*2.3)*6,ccy+Math.sin(ang*2.3)*6);S.stroke();});
  }
  S.restore();

  wallSign(lit);
  S.save();S.globalAlpha=0.14;for(var sx=wx;sx<wx+ww;sx+=18){S.fillStyle=sx%36<18?"#c9a227":"#0a0a0a";S.beginPath();S.moveTo(sx,FLOORY-8);S.lineTo(sx+9,FLOORY-8);S.lineTo(sx+18,FLOORY);S.lineTo(sx+9,FLOORY);S.closePath();S.fill();}S.restore();
  /* The floor used to be painted here, by the function that draws the WALL —
     a flat gradient plus a black seam bar, filling everything below FLOORY.
     It has moved to floorPlane(), which runs immediately after this and owns
     that band alone. Leaving it here meant anything drawn on the floor before
     the wall was silently erased, which is exactly what happened to the first
     cut of floorPlane. */
}
/* The room's name, as a thing bolted to the wall rather than as text floating
   in front of it. Drawn last inside drawBackWall so it occludes the conduit,
   the plate seams and the grime that run behind it — which is the whole reason
   the builder's tube is now allowed to stay exactly where it was. */
function wallSign(lit){
  var x=SIGN.x,y=SIGN.y,w=SIGN.w,h=SIGN.h;
  S.save();
  // the panel stands off the wall, so it drops a shadow onto it — loop 11 did
  // this by hand at a fixed offset; it now uses the same rule as every other
  // bolted prop, which is what makes the whole wall agree about where the lamp
  // is instead of each object having a private opinion
  wallShadow(x,y,w,h,1.2);
  plate(S,[[x,y],[x+w,y],[x+w,y+h],[x,y+h]],"#1b2330","#0b101a","#2b3646");
  // rolled top edge catching the lamp, and the panel's own vertical falloff
  var sh=S.createLinearGradient(0,y,0,y+h);
  sh.addColorStop(0,"rgba(190,214,246,"+(0.05+0.05*lit)+")");
  sh.addColorStop(0.35,"rgba(190,214,246,0)");
  sh.addColorStop(1,"rgba(0,0,0,0.30)");
  S.fillStyle=sh;S.fillRect(x,y,w,h);
  S.fillStyle="rgba(176,200,236,"+(0.10+0.10*lit)+")";S.fillRect(x,y,w,1.5);
  // four bolts, and the rust weeping from the lower pair
  [[x+11,y+11],[x+w-11,y+11],[x+11,y+h-11],[x+w-11,y+h-11]].forEach(function(b,i){
    S.fillStyle="#0a0e15";S.beginPath();S.arc(b[0],b[1],4,0,7);S.fill();
    S.fillStyle="#39465c";S.beginPath();S.arc(b[0],b[1],2.6,0,7);S.fill();
    S.fillStyle="rgba(196,220,255,"+(0.16*lit)+")";S.beginPath();S.arc(b[0]-0.7,b[1]-0.8,1.3,0,7);S.fill();
    if(i>1){var rg2=S.createLinearGradient(0,b[1],0,b[1]+13);
      rg2.addColorStop(0,"rgba(74,44,20,0.30)");rg2.addColorStop(1,"rgba(74,44,20,0)");
      S.fillStyle=rg2;S.fillRect(b[0]-2.5,b[1],5,13);}});
  /* Stencilled, not printed: a hard-edged glyph with a dark bite below and left
     of it, which is what paint sprayed through a mask onto rolled steel looks
     like once the room's only lamp is off to one side. The old text was a flat
     8%-alpha fill — legible as a caption, invisible as a surface. */
  var alpha=0.30+0.34*lit;
  S.font="700 34px ui-monospace,monospace";
  S.fillStyle="rgba(0,0,0,0.55)";S.fillText("SECTOR-7",x+25,y+50);
  S.fillStyle=rgba(217,178,58,alpha);S.fillText("SECTOR-7",x+24,y+48.6);
  S.fillStyle="rgba(255,236,180,"+(0.10*lit)+")";S.fillText("SECTOR-7",x+23.4,y+48);
  var word=ROOM==="builder"?"BUILDER QUARTERS":ROOM==="reviewer"?"REVIEW LAB":"DISPATCH";
  S.font="700 15px ui-monospace,monospace";
  S.fillStyle="rgba(0,0,0,0.5)";S.fillText(word,x+26,y+73);
  S.fillStyle=rgba(196,214,238,alpha*0.78);S.fillText(word,x+25,y+72);
  // a stencil worn through where the wall is rubbed, and the panel's grade tag
  S.fillStyle="rgba(27,35,48,"+(0.35+0.2*(1-lit))+")";
  S.fillRect(x+96,y+28,7,16);S.fillRect(x+188,y+22,5,11);
  S.fillStyle="rgba(150,175,205,0.18)";S.fillRect(x+w-64,y+h-24,40,2);
  S.fillStyle="rgba(150,175,205,0.10)";S.fillRect(x+w-64,y+h-19,26,2);
  S.restore();
}
/* The lamp lands on the wall.
   The one light in this room throws a volumetric cone through the air and a
   pool onto the deck, and then the 760 x 462 surface directly behind all of it
   received nothing at all: the far corner of the wall was exactly as bright as
   the patch two metres under the bulb. That is why the rooms have always read
   as a lit robot standing in front of a flat backdrop — the backdrop was not
   in the same lighting model as anything else.
   Runs after the wall attachments and before the volumetric cone, so the props
   bolted to the wall take the same falloff the wall does. Clipped to the wall
   rect, additive, in the room's own light colour: this is one lamp, and the
   room is graded to it.
   The second pass is the opposite — contact darkening where the wall meets the
   floor and where it runs out at either end. A wall that is uniformly lit to
   its own edges has no corners, and every one of these rooms had four. */
function wallKey(lit,room){
  var K=room==="builder"?[255,201,135]:room==="reviewer"?[150,196,245]:[176,150,240];
  /* Damped, not driven directly by `lit`.
     The lamp drops out for a few frames at random — a detail worth 190px of
     cone and a floor pool. Wired straight to the wall it is worth 760 x 462,
     and the first render of this pass proved it: two tiles of the same room in
     the same state came out with the wall 9 luminance steps apart, purely
     because one of them sampled a dropout frame. At that scale a strobe stops
     reading as a failing tube and starts reading as a rendering fault. The
     wall keeps a third of the swing, which is enough to tie it to the lamp. */
  lit=0.62+0.38*lit;
  S.save();
  S.beginPath();S.rect(WALL.x,WALL.y,WALL.w,FLOORY-WALL.y);S.clip();
  S.globalCompositeOperation="lighter";
  var kg=S.createRadialGradient(LAMPX,LAMPY+60,30,LAMPX,LAMPY+60,560);
  kg.addColorStop(0,rgba(K[0],K[1],K[2],0.115*lit));
  kg.addColorStop(0.42,rgba(K[0],K[1],K[2],0.048*lit));
  kg.addColorStop(1,rgba(K[0],K[1],K[2],0));
  S.fillStyle=kg;S.fillRect(WALL.x,WALL.y,WALL.w,FLOORY-WALL.y);
  S.globalCompositeOperation="source-over";
  // floor contact
  var ao=S.createLinearGradient(0,FLOORY-52,0,FLOORY);
  ao.addColorStop(0,"rgba(1,3,7,0)");ao.addColorStop(1,"rgba(1,3,7,0.42)");
  S.fillStyle=ao;S.fillRect(WALL.x,FLOORY-52,WALL.w,52);
  // the two ends, where the wall turns away
  [[WALL.x,1],[WALL.x+WALL.w,-1]].forEach(function(e){
    var eg=S.createLinearGradient(e[0],0,e[0]+e[1]*104,0);
    eg.addColorStop(0,"rgba(1,3,7,0.46)");eg.addColorStop(1,"rgba(1,3,7,0)");
    S.fillStyle=eg;S.fillRect(Math.min(e[0],e[0]+e[1]*104),WALL.y,104,FLOORY-WALL.y);});
  // and the ceiling it disappears into
  var cg2=S.createLinearGradient(0,WALL.y,0,WALL.y+72);
  cg2.addColorStop(0,"rgba(1,3,7,0.40)");cg2.addColorStop(1,"rgba(1,3,7,0)");
  S.fillStyle=cg2;S.fillRect(WALL.x,WALL.y,WALL.w,72);
  /* Aerial perspective. The wall is metres behind the unit and every prop on
     it was rendering at exactly the unit's contrast — black blacks, hard
     edges — which is what has been making the robot look pasted on rather than
     standing in front of something. Air between two things lifts the far one's
     shadows and pulls it toward the colour of the light. It is a very small
     number and it is doing more for depth than anything else in this loop. */
  S.globalAlpha=0.055;S.fillStyle=rgba(K[0],K[1],K[2],1);
  S.fillRect(WALL.x,WALL.y,WALL.w,FLOORY-WALL.y);
  S.restore();
}
/* The roof, and the near edge of the room.
   The frame had two planes: a wall with everything on it, and a unit in front
   of the wall. Above the unit was 150px of flat black doing nothing, and the
   lamp — the only light in the room — hung out of it on a stalk attached to
   the top of the canvas.
   The truss is the mid plane. It crosses in FRONT of the wall and behind the
   unit, it is what the lamp hangs from, and it closes the top of the frame:
   the rooms now have a ceiling the way they got a floor in loop 1. Kept dark
   and low-contrast on purpose — a silhouette is the correct amount of detail
   for something between the viewer and the light. */
function roofTruss(t,lit){
  var y0=26,y1=64;
  S.save();
  S.fillStyle="#080d14";S.fillRect(0,y0,DW,7);S.fillRect(0,y1,DW,7);
  S.fillStyle="rgba(120,150,190,0.07)";S.fillRect(0,y0,DW,1.4);
  S.strokeStyle="#0b111a";S.lineWidth=3.4;
  for(var w2=-30;w2<DW+40;w2+=58){                      // the lattice web
    S.beginPath();S.moveTo(w2,y1+4);S.lineTo(w2+29,y0+4);S.lineTo(w2+58,y1+4);S.stroke();}
  S.fillStyle="#0a1017";
  for(var pn=64;pn<DW;pn+=196){S.fillRect(pn,y0,10,y1-y0+7);}   // purlins crossing it
  // hangers, and the cable tray they carry
  S.fillStyle="#070c12";
  [188,372,760,948].forEach(function(hx){S.fillRect(hx,y1+7,4,26);});
  S.fillStyle="#0a1017";S.fillRect(150,y1+30,850,7);
  S.fillStyle="rgba(120,150,190,0.05)";S.fillRect(150,y1+30,850,1);
  for(var cb=160;cb<996;cb+=13){S.fillStyle="rgba(4,8,13,0.8)";S.fillRect(cb,y1+35,7,4);}
  // the lamp's own stalk, now bolted to something
  S.fillStyle="#101720";S.fillRect(LAMPX-9,y1+4,18,10);
  S.fillStyle="rgba(150,180,220,"+(0.10*lit)+")";S.fillRect(LAMPX-9,y1+4,18,1.4);
  S.restore();
}
/* Corner pilasters — where the wall stops.
   Pull the exposure up on any of these rooms and the same thing is wrong in
   all three: the back wall is a large lit rectangle that simply ENDS, on a
   hard vertical cut, with black on the other side of it. Loop 12 put a
   darkening gradient at each end, which softened the cut without explaining
   it. Nothing explains a wall ending except a corner.
   So each end gets the structural column the wall is built against: a face
   turned slightly away from the room, a bright arris where the two planes
   meet, and a shadow thrown back onto the wall it stands in front of. The
   arris is the point — a hard bright vertical line at each end of the frame is
   what makes the wall read as one face of a box rather than as a backdrop
   hung behind the set. */
function pilasters(t,lit){
  [[WALL.x,-1],[WALL.x+WALL.w,1]].forEach(function(e){
    var x=e[0],sg=e[1],w=26,y0=WALL.y-18;
    S.save();
    // shadow onto the wall, thrown inward because the lamp is between them
    var sw3=S.createLinearGradient(x-sg*w*0.5,0,x-sg*(w*0.5+46),0);
    sw3.addColorStop(0,"rgba(1,3,7,0.5)");sw3.addColorStop(1,"rgba(1,3,7,0)");
    S.fillStyle=sw3;S.fillRect(Math.min(x-sg*w*0.5,x-sg*(w*0.5+46)),WALL.y,46,FLOORY-WALL.y);
    // the returning face: darker, because it turns away from the lamp
    plate(S,[[x-sg*2,y0],[x+sg*w,y0+10],[x+sg*w,FLOORY],[x-sg*2,FLOORY]],"#101722","#070b12","#1a2432");
    // the arris
    S.fillStyle="rgba(186,212,246,"+(0.10+0.17*lit)+")";S.fillRect(x-sg*2.4,y0,2.4,FLOORY-y0);
    S.fillStyle="rgba(2,5,10,0.55)";S.fillRect(x-sg*(w*0.62),y0+8,3,FLOORY-y0-8);
    // capital and base, and a bolt line up the face
    S.fillStyle="#161e2a";S.fillRect(Math.min(x-sg*6,x+sg*w),y0,w+6,9);
    S.fillStyle="rgba(186,212,246,"+(0.07+0.08*lit)+")";S.fillRect(Math.min(x-sg*6,x+sg*w),y0,w+6,1.4);
    S.fillStyle="#131b26";S.fillRect(Math.min(x-sg*6,x+sg*w),FLOORY-16,w+6,16);
    for(var bt=y0+34;bt<FLOORY-24;bt+=54)rivet(S,x+sg*9,bt,"#33415a");
    S.restore();});
}
/* One diagonal.
   Every edge in these rooms is horizontal or vertical. The wall grid, the
   props, the bays, the truss, the tray — all of it is axis-aligned, and the
   only exceptions in fourteen loops have been the lamp cone and the builder's
   hose. A grid with no diagonal in it reads as a diagram.
   A cable hanging from the tray is the cheapest true curve there is: it is a
   catenary, it belongs on a ceiling that now exists to hang things from, and
   it crosses in front of the wall and behind the unit, which puts a line
   through the mid plane loop 14 opened up. */
function cableSwag(lit){
  [[132,470,168,0.85],[556,1006,156,0.6],[262,742,132,0.4]].forEach(function(c6){
    var x0=c6[0],x1=c6[1],dip=c6[2],a=c6[3];
    S.strokeStyle="rgba(3,6,12,"+(0.85*a)+")";S.lineWidth=3.4;
    S.beginPath();S.moveTo(x0,101);S.quadraticCurveTo((x0+x1)/2,dip*2-40,x1,101);S.stroke();
    S.strokeStyle="rgba(150,180,220,"+(0.09*a*lit)+")";S.lineWidth=1;
    S.beginPath();S.moveTo(x0,99.6);S.quadraticCurveTo((x0+x1)/2,dip*2-42,x1,99.6);S.stroke();
    S.fillStyle="#0a1017";S.fillRect(x0-3,97,6,7);S.fillRect(x1-3,97,6,7);});
}
/* The near plane. drawForeground already lays a blurred lip across the bottom
   of the frame; this is the same idea turned vertical, at the left edge, well
   out of focus. Two planes make a picture; three make a room — and an
   out-of-focus object between the viewer and the subject is the single
   cheapest way to say the camera is inside the space rather than looking
   through a window at it. Left only: the right side already has the tower, the
   steam vent and the file cabinets doing that job with real geometry. */
function nearEdge(){
  S.save();S.filter="blur(7px)";
  var ng=S.createLinearGradient(0,0,58,0);
  ng.addColorStop(0,"rgba(1,3,7,0.97)");ng.addColorStop(0.72,"rgba(1,3,7,0.86)");
  ng.addColorStop(1,"rgba(1,3,7,0)");
  S.fillStyle=ng;S.fillRect(-10,0,58,DH);
  S.fillStyle="rgba(34,48,68,0.20)";S.fillRect(40,0,5,DH);
  S.restore();
}
function drawRedBeacon(t,intensity){
  var bx=300,by=200,pulse=reduced?0.6:(0.35+0.65*Math.pow(Math.max(0,Math.sin(t*1.6)),3));
  beaconPulse=pulse*intensity;   // L8 — what the near plane catches of it
  S.fillStyle="#0f1116";rr(S,bx-2,by+12,30,6,2);S.fill();                 // mount base
  S.fillStyle="#1a1e26";rr(S,bx+2,by+1,22,13,3);S.fill();                 // cage housing
  emit(function(cx){var g2=cx.createRadialGradient(bx+13,by+8,1,bx+13,by+8,10);g2.addColorStop(0,rgba(255,140,130,Math.min(1,0.5+intensity)));g2.addColorStop(0.5,rgba(255,50,44,(0.4+0.6*pulse)*Math.min(1,0.4+intensity)));g2.addColorStop(1,"rgba(255,50,44,0)");cx.fillStyle=g2;cx.beginPath();cx.arc(bx+13,by+8,10,0,7);cx.fill();});
  S.strokeStyle="#0a0c10";S.lineWidth=1;for(var cb=0;cb<3;cb++){S.beginPath();S.moveTo(bx+6+cb*6,by+2);S.lineTo(bx+6+cb*6,by+13);S.stroke();}  // cage bars
  S.save();S.globalCompositeOperation="lighter";var rw=S.createRadialGradient(bx+13,by+30,4,bx+13,by+30,360);rw.addColorStop(0,rgba(255,50,44,0.20*pulse*intensity));rw.addColorStop(1,"rgba(255,50,44,0)");S.fillStyle=rw;S.fillRect(bx-320,by,700,520);S.restore();
}
function drawLampCone(t,lit,on,room){
  var BULB,CONE,POOL,MOTE;
  if(room==="builder"){BULB=[255,214,150];CONE=[255,201,135];POOL=[255,194,130];MOTE=[255,224,170];}
  else if(room==="reviewer"){BULB=[206,230,255];CONE=[150,196,245];POOL=[150,196,245];MOTE=[196,222,255];}
  else {BULB=[214,196,255];CONE=[176,150,240];POOL=[176,150,240];MOTE=[210,196,255];}
  S.fillStyle="#0b0f16";S.fillRect(LAMPX-3,0,6,LAMPY);
  S.fillStyle="#141a24";rr(S,LAMPX-26,LAMPY,52,18,5);S.fill();S.fillStyle="#20293a";rr(S,LAMPX-26,LAMPY,52,5,3);S.fill();
  if(!on){S.fillStyle="#0a0d13";rr(S,LAMPX-9,LAMPY+11,18,7,3);S.fill();return;}
  emit(function(cx){cx.fillStyle=rgba(BULB[0],BULB[1],BULB[2],0.9*lit);rr(cx,LAMPX-9,LAMPY+11,18,7,3);cx.fill();cx.fillStyle=rgba(255,250,235,lit);rr(cx,LAMPX-5,LAMPY+12,10,4,2);cx.fill();});
  var topY=LAMPY+18,spread=190;
  S.save();S.globalCompositeOperation="lighter";
  var cone=S.createLinearGradient(0,topY,0,FLOORY+10);cone.addColorStop(0,rgba(CONE[0],CONE[1],CONE[2],0.20*lit));cone.addColorStop(0.6,rgba(CONE[0],CONE[1],CONE[2],0.07*lit));cone.addColorStop(1,rgba(CONE[0],CONE[1],CONE[2],0));
  S.fillStyle=cone;S.beginPath();S.moveTo(LAMPX-14,topY);S.lineTo(LAMPX+14,topY);S.lineTo(LAMPX+spread,FLOORY+10);S.lineTo(LAMPX-spread,FLOORY+10);S.closePath();S.fill();
  if(!reduced)motes.forEach(function(m){var yy=topY+m.y*(FLOORY-topY);var frac=(yy-topY)/(FLOORY-topY);var half=14+frac*spread;var xx=LAMPX+(m.x-0.5)*2*half+Math.sin(t*0.6+m.s)*6;var a=(0.5+0.5*Math.sin(t*1.4+m.s))*0.5*lit*(1-frac*0.3);S.fillStyle=rgba(MOTE[0],MOTE[1],MOTE[2],a);S.fillRect(xx,yy,m.z*1.6,m.z*1.6);});
  S.restore();
  emit(function(cx){cx.save();cx.globalCompositeOperation="lighter";var p=cx.createRadialGradient(LAMPX,FLOORY,4,LAMPX,FLOORY,spread*0.9);p.addColorStop(0,rgba(POOL[0],POOL[1],POOL[2],0.5*lit));p.addColorStop(0.4,rgba(POOL[0],POOL[1],POOL[2],0.16*lit));p.addColorStop(1,rgba(POOL[0],POOL[1],POOL[2],0));cx.fillStyle=p;cx.beginPath();cx.ellipse(LAMPX,FLOORY+6,spread*0.9,42,0,0,7);cx.fill();cx.restore();});
}
function drawHolo(t,st){
  var offl=st==="offline";
  var jit=reduced?0:(Math.sin(t*40)*0.6+(Math.random()<(offl?0.16:0.03)?Math.random()*(offl?7:3):0));
  var x=HOLOX+jit,y=HOLOY,w=HOLOW,h=HOLOH;
  var C0=offl?[255,74,66]:[95,214,255]; var flick=offl?(Math.random()<0.2?0.3:0.85):1;
  S.save();S.globalCompositeOperation="lighter";S.fillStyle=rgba(C0[0],C0[1],C0[2],0.05*flick);S.beginPath();S.moveTo(ROBOX+150,FLOORY-6);S.lineTo(x+10,y+h);S.lineTo(x+w-10,y+h);S.closePath();S.fill();S.restore();
  function panel(c,alpha){c.save();c.globalAlpha=alpha*flick;
    c.fillStyle=rgba(C0[0],C0[1],C0[2],0.05);rr(c,x,y,w,h,8);c.fill();
    c.strokeStyle=rgba(C0[0],C0[1],C0[2],0.8);c.lineWidth=1.4;rr(c,x,y,w,h,8);c.stroke();
    c.strokeStyle=rgba(C0[0],C0[1],C0[2],1);c.lineWidth=2;[[x,y,1,1],[x+w,y,-1,1],[x,y+h,1,-1],[x+w,y+h,-1,-1]].forEach(function(k){c.beginPath();c.moveTo(k[0],k[1]+14*k[3]);c.lineTo(k[0],k[1]);c.lineTo(k[0]+14*k[2],k[1]);c.stroke();});
    c.fillStyle=rgba(C0[0],C0[1],C0[2],0.9);c.font="700 13px ui-monospace,monospace";
    c.fillText(offl?"◇ SIGNAL LOST":"◆ UNIT DIAGNOSTIC",x+14,y+24);
    c.fillStyle=rgba(C0[0],C0[1],C0[2],0.5);c.fillText(UNIT(),x+14,y+42);
    c.font="12px ui-monospace,monospace";
    var dd=dataOf(BOX,ROOM),up=dd.up.h+"h "+(dd.up.m<10?"0":"")+dd.up.m+"m",ql="q"+dd.queue.length+" · "+dd.repo;
    var rows=offl?[["LINK","— — —","#ff6a62"],["CRON","SILENT","#ff6a62"],["LAST","tick missed",""],["SINCE","00:04:12",""]]
      :st==="working"?[["STATE",ROOM==="builder"?"BUILDING":ROOM==="reviewer"?"REVIEWING":"DISPATCHING","#f7bd4e"],["UPTIME",up,""],["QUEUE",ql,""],["LAST",(dd.sessions.length?dd.sessions[0].out:(dd.cur?dd.cur.key:"—")),""]]
      :[["STATE","STANDBY","#5fce9b"],["UPTIME",up,""],["QUEUE",ql,""],["LAST","idle · awaiting",""]];
    rows.forEach(function(rw,i){var ry=y+70+i*24;c.fillStyle=rgba(C0[0],C0[1],C0[2],0.45);c.fillText(rw[0],x+14,ry);c.fillStyle=rw[2]||rgba(C0[0],C0[1],C0[2],0.9);c.fillText(rw[1],x+96,ry);});
    c.strokeStyle=rgba(C0[0],C0[1],C0[2],0.8);c.lineWidth=1.4;c.beginPath();
    for(var wx2=0;wx2<w-28;wx2+=3){var amp=offl?2:(st==="working"?9:4);var spd=offl?18:(st==="working"?6:2.5);var wy2=y+h-24+Math.sin(wx2*0.25+t*spd)*amp*Math.sin(wx2*0.05)+(offl&&Math.random()<0.1?(Math.random()-0.5)*10:0);if(wx2===0)c.moveTo(x+14+wx2,wy2);else c.lineTo(x+14+wx2,wy2);}c.stroke();
    c.globalAlpha=alpha*flick*0.5;c.fillStyle=rgba(C0[0],C0[1],C0[2],0.06);for(var sl=y+4;sl<y+h;sl+=4)c.fillRect(x+2,sl,w-4,1);
    if(!offl){var sb=y+((t*60)%h);c.fillStyle=rgba(C0[0],C0[1],C0[2],0.10);c.fillRect(x+2,sb,w-4,10);}
    c.restore();}
  panel(S,0.9);panel(G,0.7);
}
/* The floor the whole room stands on. There wasn't one: below FLOORY the scene
   was the same flat #02040a as the void above the wall, so every unit and every
   prop was pasted onto a hole rather than standing in a room, and the contact
   shadows had no surface to land on. One receding plane, tinted per room —
   which is also the cheapest way to make three rooms that share a wall, a
   ceiling and a lamp stop reading as the same room with different posters. */
function floorPlane(t,lit,st){
  var off=st==="offline", VPX=DW*0.5, H=DH-FLOORY;
  var warm=ROOM==="builder", cool=ROOM==="reviewer";
  /* These read brighter than they look on paper only because everything below
     FLOORY is then hit twice — by drawForeground's blurred lip and by the
     final vignette, which is at its strongest in exactly this band. Tuned
     against the composite, not against this fill. */
  var base=warm?[62,51,38]:cool?[42,57,76]:[50,54,63];
  var k=off?0.42:1;
  S.save();
  // the wall's own contact shadow, where it meets the floor
  S.fillStyle="rgba(0,0,0,0.6)";S.fillRect(0,FLOORY-3,DW,3);
  var fg=S.createLinearGradient(0,FLOORY,0,DH);
  fg.addColorStop(0,rgba(base[0]*k,base[1]*k,base[2]*k,1));
  fg.addColorStop(0.35,rgba(base[0]*0.62*k,base[1]*0.62*k,base[2]*0.62*k,1));
  fg.addColorStop(1,"#01030700");
  S.fillStyle=fg;S.fillRect(0,FLOORY,DW,H);
  /* Seams converge on the same vanishing point the wall grid implies, so the
     floor agrees with the perspective already on screen instead of announcing
     a second one. */
  S.strokeStyle=rgba(120,150,190,0.05*k);S.lineWidth=1;
  for(var sx2=-720;sx2<DW+720;sx2+=150){S.beginPath();S.moveTo(VPX+(sx2-VPX)*0.16,FLOORY);S.lineTo(sx2,DH);S.stroke();}
  [7,18,34,56,86].forEach(function(dy,i){S.strokeStyle=rgba(120,150,190,(0.055-i*0.008)*k);S.beginPath();S.moveTo(0,FLOORY+dy);S.lineTo(DW,FLOORY+dy);S.stroke();});
  /* The lip where floor meets wall. A hard bright edge here is what stops the
     two planes from reading as one dark field — it is doing more work than the
     whole gradient above it. */
  S.fillStyle=rgba(150,180,215,0.13*lit*k);S.fillRect(0,FLOORY,DW,1);
  S.fillStyle=rgba(150,180,215,0.05*lit*k);S.fillRect(0,FLOORY+1,DW,2);

  if(warm){
    /* Oil and scorch. A fabrication bay floor that is evenly clean is a
       rendering, not a workshop — and the stains sell scale, because they are
       the only thing down here with a size the eye already knows. */
    /* Kept inside FLOORY..FLOORY+40. drawForeground's blurred lip rises to
       about DH-96 at mid-screen and the vignette piles on below that, so
       anything painted lower than ~+40 is painted where nobody can see it. */
    [[300,13,80,0.62],[566,24,120,0.5],[858,10,64,0.56],[190,30,58,0.44]].forEach(function(o){
      var og=S.createRadialGradient(o[0],FLOORY+o[1],2,o[0],FLOORY+o[1],o[2]);
      og.addColorStop(0,rgba(6,5,4,o[3]*k));og.addColorStop(1,"rgba(6,5,4,0)");
      S.fillStyle=og;S.beginPath();S.ellipse(o[0],FLOORY+o[1],o[2],o[2]*0.32,0,0,7);S.fill();});
  } else if(cool){
    /* Sealed lab floor: it reflects. A smeared, vertically-squashed echo of
       the diff wall is enough — a real mirror would double the noise and read
       as a bug. */
    S.save();S.globalCompositeOperation="lighter";
    var rf=S.createLinearGradient(0,FLOORY,0,FLOORY+70);
    rf.addColorStop(0,rgba(120,180,240,0.085*k));rf.addColorStop(1,"rgba(120,180,240,0)");
    S.fillStyle=rf;S.fillRect(250,FLOORY,420,70);
    // specular pool directly under the lamp
    var sp=S.createRadialGradient(ROBOX,FLOORY+16,3,ROBOX,FLOORY+16,210);
    sp.addColorStop(0,rgba(180,215,255,0.10*lit*k));sp.addColorStop(1,"rgba(180,215,255,0)");
    S.fillStyle=sp;S.beginPath();S.ellipse(ROBOX,FLOORY+16,210,26,0,0,7);S.fill();S.restore();
  } else {
    /* Dispatch floors are painted, because dispatch is about where a thing
       goes next. The lane runs toward the console the triage unit works at. */
    /* Same band constraint as the builder's stains: the lane has to live in
       FLOORY..FLOORY+40 or the foreground lip swallows it. */
    S.save();S.globalAlpha=(off?0.22:0.62);
    S.strokeStyle="rgba(201,162,39,0.30)";S.lineWidth=2;
    S.beginPath();S.moveTo(0,FLOORY+9);S.lineTo(DW,FLOORY+9);S.moveTo(0,FLOORY+39);S.lineTo(DW,FLOORY+39);S.stroke();
    for(var cxp=48;cxp<DW;cxp+=124){S.strokeStyle="rgba(201,162,39,0.30)";S.lineWidth=3.5;S.beginPath();
      S.moveTo(cxp,FLOORY+16);S.lineTo(cxp+22,FLOORY+24);S.lineTo(cxp,FLOORY+32);S.stroke();}
    S.restore();
  }
  S.restore();
}
function drawFloorFog(t){S.save();S.globalCompositeOperation="lighter";floorHaze.forEach(function(f){var x=((f.x+t*f.sp)%1.2-0.1)*DW;var y=FLOORY+(f.y-0.8)*DH*0.4;var gr=S.createRadialGradient(x,y,10,x,y,260);gr.addColorStop(0,rgba(90,120,150,f.a));gr.addColorStop(1,"rgba(90,120,150,0)");S.fillStyle=gr;S.beginPath();S.ellipse(x,y,260,50,0,0,7);S.fill();});S.restore();}
function drawSteam(t){if(reduced)return;S.save();S.globalCompositeOperation="lighter";var vx=1010,vy=FLOORY-30;S.fillStyle="#0c1219";rr(S,vx,vy,40,26,3);S.fill();steam.forEach(function(s){var p=(s.p+t*0.06)%1;var yy=vy-p*180;var xx=vx+20+Math.sin(t*0.8+s.sway)*24*p;var a=(1-p)*0.10;var rad=8+p*46;var gr=S.createRadialGradient(xx,yy,2,xx,yy,rad);gr.addColorStop(0,rgba(120,150,175,a));gr.addColorStop(1,"rgba(120,150,175,0)");S.fillStyle=gr;S.beginPath();S.arc(xx,yy,rad,0,7);S.fill();});S.restore();}
/* A near-foreground layer, per room.
   Every room was wall / props / robot, all at one focal distance, so the frame
   had no depth in front of the subject — only behind it. One blurred object
   close to camera does more for the sense of a real space than anything that
   could be added at the back, and it costs a shape and a blur. Drawn before
   drawForeground so the floor lip still closes the frame. */
function roomForeground(t,st){
  S.save();S.filter="blur(4px)";
  if(ROOM==="builder"){
    // a chain hoist hanging just off-camera-left, and a girder crossing top-right
    S.strokeStyle="rgba(9,13,20,0.95)";S.lineWidth=9;
    S.beginPath();S.moveTo(96,0);S.lineTo(112,470);S.stroke();
    S.strokeStyle="rgba(40,52,70,0.5)";S.lineWidth=2;
    S.beginPath();S.moveTo(92,0);S.lineTo(108,470);S.stroke();
    S.fillStyle="rgba(9,13,20,0.95)";S.fillRect(84,470,40,54);
    S.save();S.globalAlpha=0.9;S.fillStyle="#080c13";
    S.beginPath();S.moveTo(DW,0);S.lineTo(DW,86);S.lineTo(1004,26);S.lineTo(1004,0);S.closePath();S.fill();S.restore();
  } else if(ROOM==="reviewer"){
    // the edge of a glass partition the camera is looking through
    var gp=S.createLinearGradient(0,0,150,0);
    gp.addColorStop(0,"rgba(150,190,235,0.10)");gp.addColorStop(1,"rgba(150,190,235,0)");
    S.fillStyle=gp;S.fillRect(0,0,150,DH);
    S.fillStyle="rgba(10,16,24,0.9)";S.fillRect(120,0,13,DH);
    S.fillStyle="rgba(150,190,235,0.12)";S.fillRect(120,0,2,DH);
  } else {
    // a bundle of cable dropping past the lens, the way a dispatch room is wired
    [[168,-14],[186,8],[204,-6]].forEach(function(cb,ci2){
      S.strokeStyle=ci2===1?"rgba(12,17,25,0.95)":"rgba(9,13,20,0.9)";S.lineWidth=ci2===1?11:7;
      S.beginPath();S.moveTo(cb[0],0);S.quadraticCurveTo(cb[0]+cb[1],250,cb[0]+cb[1]*2.2,520);S.stroke();});
    S.strokeStyle="rgba(52,66,88,0.35)";S.lineWidth=2;
    S.beginPath();S.moveTo(186,0);S.quadraticCurveTo(194,250,203,520);S.stroke();
  }
  S.restore();
}
function drawForeground(){S.save();S.filter="blur(3px)";S.fillStyle="#010307";S.beginPath();S.moveTo(0,DH);S.lineTo(0,DH-54);S.quadraticCurveTo(DW*0.5,DH-96,DW,DH-40);S.lineTo(DW,DH);S.closePath();S.fill();S.strokeStyle="rgba(30,44,62,0.4)";S.lineWidth=2;S.beginPath();S.moveTo(0,DH-52);S.quadraticCurveTo(DW*0.5,DH-94,DW,DH-38);S.stroke();S.restore();}

/* ===================== CURRENT (flat) ===================== */
function drawCurrent(t){
  S.setTransform(1,0,0,1,0,0);S.globalAlpha=1;S.globalCompositeOperation="source-over";S.filter="none";
  S.clearRect(0,0,DW,DH);S.fillStyle="#0b111c";S.fillRect(0,0,DW,DH);
  var wx=250,ww=760,wy=150;S.fillStyle="#121b2c";S.fillRect(wx,wy,ww,FLOORY-wy);S.fillStyle="#0e1626";S.fillRect(0,FLOORY,DW,DH-FLOORY);
  S.strokeStyle="#22304a";S.lineWidth=1;for(var px=wx;px<wx+ww;px+=64){S.beginPath();S.moveTo(px,wy);S.lineTo(px,FLOORY);S.stroke();}
  [[300],[900],[1040]].forEach(function(d){var x=d[0];S.fillStyle="#171f30";S.fillRect(x,FLOORY-260,90,260);S.fillStyle="#2a3852";S.fillRect(x,FLOORY-260,90,6);for(var u=0;u<8;u++){S.fillStyle="#0e1626";S.fillRect(x+6,FLOORY-250+u*30,78,22);S.fillStyle=(u%2?"#3aa06a":"#22344e");S.fillRect(x+72,FLOORY-247+u*30,5,5);}});
  var cx=470,fy=FLOORY,base="#f6a04d",bd="#8a5a2a",bl="#ffce9a";function fr(x,y,w,h,c){S.fillStyle=c;S.fillRect(x,y,w,h);}
  fr(cx-16,fy-58,10,58,bd);fr(cx+6,fy-58,10,58,bd);fr(cx-24,fy-118,48,64,base);fr(cx-24,fy-118,48,3,bl);
  fr(cx-36,fy-116,12,20,base);fr(cx+24,fy-116,12,20,base);fr(cx-34,fy-112,10,54,base);fr(cx+24,fy-112,10,54,base);
  fr(cx-20,fy-166,40,44,bl);fr(cx-16,fy-150,32,12,"#0a0f18");fr(cx-12,fy-146,24,4,"#5cb4ff");fr(cx-8,fy-96,16,16,"#0b1119");fr(cx-4,fy-92,8,8,"#5cb4ff");
  S.fillStyle="#c7d4e4";S.font="700 15px ui-monospace,monospace";S.textAlign="center";S.fillText("claude-builder",cx,fy+34);S.textAlign="left";
  C.setTransform(1,0,0,1,0,0);C.globalAlpha=1;C.globalCompositeOperation="source-over";C.filter="none";C.clearRect(0,0,DW,DH);C.drawImage(scene,0,0);
}

/* ===================== COMPOSE + BLIT ===================== */
var cv=document.getElementById("scene"),X=cv.getContext("2d");
var VW=0,VH=0,dpr=1,dstX=0,dstY=0,dstW=0,dstH=0;
function resize(){dpr=Math.min(2,window.devicePixelRatio||1);VW=window.innerWidth;VH=window.innerHeight;cv.width=Math.floor(VW*dpr);cv.height=Math.floor(VH*dpr);X.setTransform(dpr,0,0,dpr,0,0);var s=Math.min(VW/DW,VH/DH);dstW=DW*s;dstH=DH*s;dstX=(VW-dstW)/2;dstY=(VH-dstH)/2;}
window.addEventListener("resize",resize);
function tintTo(dst,src,r,g,b){var c=dst.getContext("2d");c.globalCompositeOperation="source-over";c.globalAlpha=1;c.filter="none";c.clearRect(0,0,DW,DH);c.drawImage(src,0,0);c.globalCompositeOperation="multiply";c.fillStyle="rgb("+r+","+g+","+b+")";c.fillRect(0,0,DW,DH);c.globalCompositeOperation="source-over";}
function blit(){X.imageSmoothingEnabled=true;X.fillStyle="#000";X.fillRect(0,0,VW,VH);
  if(MODE==="target"){var dx=1.1;tintTo(tintR,comp,255,0,0);tintTo(tintG,comp,0,255,0);tintTo(tintB,comp,0,0,255);X.globalCompositeOperation="lighter";X.drawImage(tintG,dstX,dstY,dstW,dstH);X.drawImage(tintR,dstX+dx,dstY,dstW,dstH);X.drawImage(tintB,dstX-dx,dstY,dstW,dstH);X.globalCompositeOperation="source-over";}
  else{X.drawImage(comp,dstX,dstY,dstW,dstH);}}
var lastT=0;
/* dev/whiteboard.html boots the whole app — that is the point of it, the
   renderer has to be the shipped one — and then hides the stage and draws its
   own grid. The loop underneath was still painting a full fleet into a hidden
   canvas every frame, which is merely wasteful while a cell is cheap and is
   not once a cell renders rooms: the map's tiles would queue behind the hidden
   view's. FLOORDEV.pause stops the painting, not the page. */
var devPaused=false;
function frame(ms){var t=ms/1000,dt=Math.min(0.05,(ms-lastT)/1000)||0.016;lastT=ms;if(!devPaused){if(VIEW==="floor"){drawFloor(t);}else{drawTarget(t,dt);blit();}}requestAnimationFrame(frame);}

function refreshChrome(){
  document.getElementById("modelabel").textContent=STATE.toUpperCase();
  /* The fourth site that read "offline" and said SILENT. Same rule as the
     headline, the CRON vital and the big card: the alarm is for a box that
     should be ticking and is not (#203). */
  var stw=STATE==="offline"?stoppedWord(dataOf(BOX,ROOM)):"";
  document.getElementById("fl").textContent=UNIT()+" · "+(stw||(STATE==="offline"?"CRON SILENT":STATE))+" · sector-7";
  var sub=document.getElementById("sub");if(sub)sub.textContent=AGENT+" · "+ROLEWORD()+" quarters — detailed god-view cell";
  var rv=document.getElementById("room-version");if(rv)rv.textContent=(LIVEMETA&&LIVEMETA.version)||"version unavailable";
}
var _un=document.getElementById("un");if(_un)_un.addEventListener("click",function(e){var b=e.target.closest("button");if(!b)return;AGENT=b.dataset.a;[].forEach.call(this.querySelectorAll("button"),function(x){x.classList.toggle("on",x===b);});refreshChrome();populateDash();});
var _stg=document.getElementById("stg");if(_stg)_stg.addEventListener("click",function(e){var b=e.target.closest("button");if(!b)return;STATE=b.dataset.s;[].forEach.call(this.querySelectorAll("button"),function(x){x.className=(x===b?"on "+(STATE==="working"?"w":STATE==="offline"?"o":""):"");});refreshChrome();populateDash();});
var _rm=document.getElementById("rm");if(_rm)_rm.addEventListener("click",function(e){var b=e.target.closest("button");if(!b)return;ROOM=b.dataset.r;[].forEach.call(this.querySelectorAll("button"),function(x){x.classList.toggle("on",x===b);});refreshChrome();populateDash();});
/* ---- command-center wiring ---- */
buildTiles();buildOps();
for(var _sd=0;_sd<6;_sd++)tickerEvent();
/* Opened as a file there is no collector to act through, so the operator
   controls stay shown-but-disabled. Serving the page with `crew floor` is what
   turns them on — goLive() clears every .woff below. */
var CTL_TIP="Open this page with `crew floor` — a served page drives the boxes from the host.";
if(!LIVE){["g-start","g-stop","g-wake","g-reg","g-roster","a-pause","a-restart","c-send"].forEach(function(id){var e=document.getElementById(id);if(e){e.classList.add("woff");e.title=CTL_TIP;}});var cin=document.getElementById("c-in");if(cin){cin.disabled=true;cin.classList.add("woff");cin.placeholder="Messaging needs a served page — run: crew floor";}}
/* Fleet-wide actions. "Start/Stop all" are box lifecycle, not a mood: they
   power the roster's boxes up and down. "Wake silent" resumes a paused crontab
   and starts a stopped box — it does NOT start a model session, because a box
   whose cron is dead has no evidence anyone asked for one. */
document.getElementById("g-start").addEventListener("click",function(){if(!LIVE)return;if(confirm("Start every roster box?"))cmd("start-all");});
document.getElementById("g-stop").addEventListener("click",function(){if(!LIVE)return;if(confirm("Stop every roster box? Running sessions are lost."))cmd("stop-all");});
document.getElementById("g-reg").addEventListener("click",function(){openRegistries("");});
document.getElementById("g-roster").addEventListener("click",function(){openRoster();});
document.getElementById("g-wake").addEventListener("click",function(){if(!LIVE)return;cmd("wake-silent");});
setInterval(tickOps,1000);setInterval(updateCurrent,1000);
/* The access panel is re-rendered on every poll, so its buttons are handled by
   delegation on the rail rather than bound per render. */
var _railL=document.querySelector(".rail-l");
if(_railL)_railL.addEventListener("click",function(e){
  if(!LIVE)return;
  var box=BOX,d=dataOf(BOX,ROOM);
  var pw=e.target.closest(".pw");
  if(pw){
    var on=pw.dataset.pw==="on";
    if(!on&&!confirm("Power off "+box+"? Any running session is lost."))return;
    cmd(on?"power-on":"power-off",{box:box});return;
  }
  var b=e.target.closest(".lbtn");if(!b)return;
  if(b.id==="ac-restart"){restartClick(box,d);}
  /* Its own verb on the wire too, not a flag on power-off: the collector must
     never be able to reach a force stop except by being asked for one. */
  else if(b.id==="ac-force"){if(confirm("Force stop "+box+"? The guest is KILLED where it stands — this is `incus stop --force`, not a shutdown, and any running session is lost. Use it when a graceful stop has hung."))cmd("force-stop",{box:box});}
  else if(b.id==="ac-repo"){if(d.repo)window.open(repoURL(d.repo),"_blank","noopener");}
  else if(b.id==="ac-term"){
    /* A browser cannot open a shell into a box. Hand over the command the
       operator would type instead of pretending otherwise. */
    var c="box shell "+box;
    if(navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(c).then(function(){setStatus("copied: "+c,false);},function(){setStatus(c,false);});
    else setStatus(c,false);
  }
  else if(b.id==="ac-logs")openLogs(box,"");
  else if(b.id==="ac-reg")openRegistries(box);
});
/* Raw logs come back as text/plain from the collector, which tails them in the
   box — the page never gets shell access to a path.

   Shown in an in-page overlay, NOT window.open: the window would be opened in
   the fetch's .then(), which browsers no longer treat as user-initiated, so a
   default popup blocker eats it and the button appears to do nothing. */
function openLogs(box,file,session){
  setStatus("fetching logs…",false);
  fetch(apiURL("/api/logs?box="+encodeURIComponent(box)+(file?"&file="+encodeURIComponent(file):"")))
    .then(function(r){return r.text();})
    .then(function(txt){
      var ov=document.getElementById("logov");
      if(!ov){
        ov=document.createElement("div");ov.id="logov";
        ov.innerHTML='<div class="logbox"><div class="loghd"><span id="logttl"></span><button id="logx">✕ close</button></div><pre id="logtx"></pre></div>';
        document.body.appendChild(ov);
        ov.addEventListener("click",function(e){if(e.target===ov||e.target.id==="logx")closeLogs();});
      }
      document.getElementById("logttl").textContent=session
        ?box+" · "+session.kind+" "+session.key+" · "+session.out+" · "+fmtDur(session.dur)+" · last 500 lines"
        :box+" · "+(file||"duty.log");
      document.getElementById("logtx").textContent=txt||"(empty)";
      ov.style.display="flex";
      var tx=document.getElementById("logtx");tx.scrollTop=tx.scrollHeight;
      setStatus("logs: "+box,false);
    })
    .catch(function(e){setStatus("logs failed: "+e.message,true);});
}
function closeLogs(){var ov=document.getElementById("logov");if(ov)ov.style.display="none";}
/* ===================== the watch registries (#488) =====================

   The fleet's scope is two host files — the work registry every duty module
   is bounded by, and the extra handoff targets the notifier sweeps — and
   re-pointing one droid at a different repository used to be an ssh and
   several edits by hand. Both are editable here, fleet-wide and per box.

   AN OVERLAY, NOT A LIVE PANEL, and that is the whole reason this is not
   rendered into the rail beside VITALS. populateDash() repaints the rails on
   every poll; a textarea in there would have the operator's half-typed list
   replaced under their cursor every 15 seconds. An editor is opened, used and
   closed, so it is opened on demand and painted once.

   It reads /api/registries at OPEN time rather than from the poll cache, so
   what an operator edits is the file as it is on disk right now — a hand edit
   made in vim between two clicks is picked up, with no floor restart (D4). */
var REGS=null;
function pollRegistries(){
  if(location.protocol==="file:")return Promise.resolve(null);
  return api("/api/registries").then(function(r){REGS=r;return r;}).catch(function(){return null;});
}
/* The one summary that belongs on the always-visible cell: how many
   repositories this box watches, and whether that is the whole fleet-wide list
   or a selection from it. A box quietly narrowed to a stale slice is the
   failure this layer can introduce, so the selection is the loud half — an
   operator scanning the console must not have to open an editor to find it.

   A narrowed box reads `3/7`, never a bare `3`: the count alone cannot say
   whether a small number is a small fleet or a box somebody pointed at one
   board, and those want opposite reactions. SELECTED and not DIRTY, because a
   narrowed member is a member doing what it was asked (operator, 2026-08-29)
   — the word here is the same judgement hire_guard makes in the CLI. */
function registryRow(box){
  if(!REGS||!REGS.boxes||!REGS.boxes[box])return [];
  var c=REGS.boxes[box],sel=!c.work.inherited||!c.notify.inherited;
  function part(kind,label){
    var n=c[kind].entries.length;
    return (c[kind].inherited?n:n+"/"+REGS.fleet[kind].entries.length)+" "+label;
  }
  return [["Registry",part("work","work")+" · "+part("notify","notify")+(sel?" · SELECTED":"")]];
}
var REGKINDS=[["work","WORK REGISTRY","the boards this box works: issues, reviews, author-side duties"],
              ["notify","NOTIFY REGISTRY","extra handoff targets the operator notifier sweeps"]];
/* openRegistries(BOX) — BOX "" is the fleet-wide pair, a box name is that
   box's own layer. One editor for both scopes rather than two: the shapes are
   identical and the only difference is which buttons a scope can offer, so a
   second component would be a second place for the two to drift apart. */
function openRegistries(box){
  if(!LIVE){setStatus("registries are live-only — run the collector to edit them",true);return;}
  setStatus("reading registries…",false);
  pollRegistries().then(function(r){
    if(!r){setStatus("could not read the registries",true);return;}
    var ov=document.getElementById("regov");
    if(!ov){
      ov=document.createElement("div");ov.id="regov";
      ov.innerHTML='<div class="logbox"><div class="loghd"><span id="regttl"></span><button id="regx">✕ close</button></div><div class="regbody" id="regbody"></div></div>';
      document.body.appendChild(ov);
      ov.addEventListener("click",function(e){if(e.target===ov||e.target.id==="regx")closeRegistries();});
      document.getElementById("regbody").addEventListener("click",onRegistryClick);
    }
    ov.dataset.box=box||"";
    document.getElementById("regttl").textContent=(box?box+" · watch registries":"fleet-wide watch registries")
      +" · "+r.config_dir;
    document.getElementById("regbody").innerHTML=REGKINDS.map(function(k){
      var kind=k[0],cell=box?r.boxes[box][kind]:r.fleet[kind],inherited=box?cell.inherited:false;
      /* The fleet-wide file's own path when the box is inheriting: an override
         has no file yet, and printing a path nothing has written would read as
         a file the operator could go and open. */
      var path=box?(inherited?r.fleet[kind].path+" (inherited)":cell.path):cell.path;
      /* THE FLEET-WIDE FILE THE DEFINITION DOES NOT HAVE YET. `notify-repos.txt`
         is optional in a hand-built definition and the CLI's config_file
         resolves an absent one to the shipped examples/ file — nine live
         repositories it stages to every box. Rendering that as an empty list
         would invite an operator to "fill it in" and silently drop eight sweep
         targets the fleet was working, so the fallback is said out loud, with
         the path a save will actually write.
         "the CLI" rather than the command's own name on purpose: the console's
         named-verb roster reads `crew <word>` anywhere in this file as an
         operator command the page offers, and a sentence about resolution is
         not one. */
      var fk=r.fleet[kind],note="";
      if(fk.present===false&&fk.served_from){
        note='<div class="regnote">'+esc(fk.path)+' does not exist in this fleet definition. '
          +'The '+fk.entries.length+' entr'+(fk.entries.length===1?"y":"ies")+' below '
          +'come from the shipped '+esc(fk.served_from)+', which is what <code>crew</code> '
          +'stages to a box too. Saving writes the definition\'s own file, and it wins from then on.</div>';
      }
      /* The fleet-wide scope is a free list — it IS the universe, so there is
         nothing to bound it by and an operator adding a board types its name.
         A box's scope is a SELECTION from that universe (operator,
         2026-08-29): it can never name a repository the fleet-wide list does
         not, so the legal values are finite, known and already on screen, and
         a textarea there would exist only for the collector to refuse. */
      var editor;
      if(!box){
        editor='<textarea class="regta" spellcheck="false">'+esc(cell.entries.join("\n"))+'</textarea>';
      }else if(!r.fleet[kind].entries.length){
        /* Said as itself rather than drawn as an empty list of switches: with
           no universe there is no selection to make, and the operator's next
           move is a fleet-wide edit and not a narrower box. */
        editor='<div class="regempty">the fleet-wide list names no repositories — there is nothing for this box to select. Edit the fleet-wide registry first.</div>';
      }else{
        var chosen={};cell.entries.forEach(function(e){chosen[e]=1;});
        editor='<div class="regsel">'+r.fleet[kind].entries.map(function(e){
          return '<label class="regopt"><input type="checkbox" value="'+esc(e)+'"'
            +(chosen[e]?' checked':'')+'><span>'+esc(e)+'</span></label>';
        }).join('')+'</div>';
      }
      return '<div class="regblk" data-kind="'+kind+'">'
        +'<div class="wt"><span class="dot"></span>'+k[1]
        +(box?'<span class="regsrc '+(inherited?"inherit":"override")+'">'+(inherited?"inherited":"selected")+'</span>':'')
        +'</div>'
        +'<div class="regpath" title="'+esc(k[2])+'">'+esc(path)+'</div>'
        +note
        +editor
        +'<div class="regacts">'
        +'<button class="lbtn" data-reg="save">'+(box?"Save selection":"Save")+'</button>'
        +(box?'<button class="lbtn" data-reg="inherit"'+(inherited?' style="opacity:.5"':'')+'>Inherit the fleet-wide list</button>':'')
        +'</div></div>';
    }).join('');
    ov.style.display="flex";
    setStatus("registries: "+(box||"fleet-wide"),false);
  });
}
function closeRegistries(){var ov=document.getElementById("regov");if(ov)ov.style.display="none";}
function onRegistryClick(e){
  var b=e.target.closest("[data-reg]");if(!b)return;
  var blk=b.closest(".regblk"),kind=blk.dataset.kind,box=document.getElementById("regov").dataset.box||"";
  if(b.dataset.reg==="inherit"){
    /* Confirmed because it is a DELETION: the override file goes, and with it
       whatever narrowing somebody applied to this box on purpose. Clearing is
       a distinct act from writing the fleet-wide list into the override — the
       cleared box follows a later widening and a pinned one does not — so the
       question names the consequence rather than the file. */
    if(!confirm("Clear "+box+"'s "+kind+" selection? It goes back to following the fleet-wide list, including any later widening."))return;
    return cmd("registry-inherit",{box:box,kind:kind}).then(function(){openRegistries(box);});
  }
  /* Two editors, one submission shape: the switches when this is a box's
     selection, the free list when it is the fleet-wide registry itself. An
     empty selection is a real answer — a box deliberately watching nothing —
     so this never falls back to "nothing checked means everything". */
  var ta=blk.querySelector(".regta"),entries;
  if(ta){
    entries=ta.value.split("\n").map(function(s){return s.trim();}).filter(Boolean);
  }else{
    entries=[].map.call(blk.querySelectorAll(".regopt input:checked"),function(i){return i.value;});
  }
  var extra={kind:kind,entries:entries};
  if(box)extra.box=box;
  return cmd(box?"registry-override":"registry-set",extra).then(function(r){
    /* Re-open on SUCCESS only. A refusal leaves the operator's text exactly as
       they typed it, beside the reason the collector gave in the status line —
       repainting from disk there would throw away the edit they now have to
       correct, which is the one moment the field's contents matter most. */
    if(r&&r.ok)openRegistries(box);
  });
}
/* ===================== the roster (#764) =====================

   fleet.roster IS the fleet — one line per box: name, agent, role(s), and the
   gold box/snapshot it is minted from — and it was the one piece of the
   definition this console showed and could not change. It is edited here the
   way the registries are: an overlay opened on demand, painted once from the
   file as it is on disk right now (a hand edit between two clicks is picked
   up), saved whole, refused whole with the line and the reason when a line is
   wrong.

   SAVING WRITES THE DEFINITION AND NOTHING ELSE. A new line becomes a box when
   the operator runs `crew up` on the host (it creates, starts and hires every
   roster box; the login is theirs, by hand). A removed line's box is left
   alone: the console stops watching it, and nothing is ever deleted. The
   collector reads the roster on every poll, so the edit is live at the next. */
var ROSTER_OPTS={agents:[],roles:[]};
function openRoster(){
  if(!LIVE){setStatus("the roster is live-only — run the collector to edit it",true);return;}
  setStatus("reading the roster…",false);
  api("/api/roster").then(function(r){
    if(!r||!r.members){setStatus("could not read the roster",true);return;}
    var ov=document.getElementById("rosov");
    if(!ov){
      ov=document.createElement("div");ov.id="rosov";
      ov.innerHTML='<div class="logbox"><div class="loghd"><span id="rosttl"></span><button id="rosx">✕ close</button></div><div class="regbody" id="rosbody"></div></div>';
      document.body.appendChild(ov);
      ov.addEventListener("click",function(e){if(e.target===ov||e.target.id==="rosx")closeRoster();});
      document.getElementById("rosbody").addEventListener("click",onRosterClick);
    }
    ROSTER_OPTS={agents:r.agents||[],roles:r.roles||[]};
    document.getElementById("rosttl").textContent="fleet roster · "+r.path;
    /* Each row's standing is read off the poll's own snapshot, never re-asked:
       a line with no box yet is the TARGET fleet (the roster deliberately names
       boxes the CLI has not created, #77), and that is said as such. */
    var units={};((LIVEMETA&&LIVEMETA.units)||[]).forEach(function(u){units[u.box]=u;});
    document.getElementById("rosbody").innerHTML=
      '<div class="regnote">One line per box: its name, the agent it runs, its role(s), and the box/snapshot it is minted from (optional). '
      +'Saving writes <code>fleet.roster</code> on the host and nothing else: a new line becomes a box when you run <code>crew up</code> there '
      +'(it creates, starts and hires every roster box; the login is yours, by hand). A removed line\'s box is left alone — the console stops watching it, nothing is ever deleted.</div>'
      +'<table class="rostbl"><thead><tr><th>box</th><th>agent</th><th>roles</th><th>from (box/snapshot)</th><th></th></tr></thead><tbody id="roslist">'
      +r.members.map(function(m){return rosterRow(m,units[m.box]);}).join('')
      +'</tbody></table>'
      +'<div class="regacts"><button class="lbtn" data-ros="add">+ Add a box</button><button class="lbtn" data-ros="save">Save roster</button></div>';
    ov.style.display="flex";
    setStatus("roster: "+r.members.length+" member"+(r.members.length===1?"":"s"),false);
  }).catch(function(){setStatus("could not read the roster",true);});
}
function rosterStanding(u){
  if(!u)return "new";
  if(u.hired==="yes")return "hired";
  if(/not created|inventory/.test(u.note||""))return "not created";
  return u.hired==="no"?"not hired":"";
}
function rosterRow(m,u){
  var chosen={};(m.room||"").split(",").forEach(function(x){if(x)chosen[x]=1;});
  var st=rosterStanding(u);
  return '<tr class="rosrow">'
    +'<td><input class="rosin" data-k="box" value="'+esc(m.box||"")+'" placeholder="box-name" spellcheck="false"'+(u?' readonly title="an existing box keeps its name — a renamed line would be a second box"':'')+'>'
    +(st?'<div class="rosst'+(st==="new"?" new":"")+'">'+esc(st)+'</div>':'')+'</td>'
    +'<td><select class="rosin" data-k="agent">'+ROSTER_OPTS.agents.map(function(a){return '<option'+(a===m.agent?' selected':'')+'>'+esc(a)+'</option>';}).join('')+'</select></td>'
    +'<td><div class="regsel rossel">'+ROSTER_OPTS.roles.map(function(x){return '<label class="regopt"><input type="checkbox" value="'+esc(x)+'"'+(chosen[x]?' checked':'')+'><span>'+esc(x)+'</span></label>';}).join('')+'</div></td>'
    +'<td><input class="rosin" data-k="from" value="'+esc(m.from||"")+'" placeholder="(blank mint)" spellcheck="false"></td>'
    +'<td><button class="lbtn rosdrop" data-ros="drop" title="remove this line (the box itself is left alone)">✕</button></td></tr>';
}
function closeRoster(){var ov=document.getElementById("rosov");if(ov)ov.style.display="none";}
function onRosterClick(e){
  var b=e.target.closest("[data-ros]");if(!b)return;
  var list=document.getElementById("roslist");
  if(b.dataset.ros==="add"){
    list.insertAdjacentHTML("beforeend",rosterRow({box:"",agent:ROSTER_OPTS.agents[0]||"",room:"",from:""},null));
    var inp=list.lastElementChild.querySelector('[data-k="box"]');if(inp)inp.focus();
    return;
  }
  if(b.dataset.ros==="drop"){
    var tr=b.closest("tr"),name=tr.querySelector('[data-k="box"]').value.trim();
    /* Confirmed because it is a REMOVAL from the fleet's definition, even
       though the box stays: the console stops watching it and the host tick
       stops waking it. The question names what does and does not happen. */
    if(name&&!confirm("Remove "+name+" from the roster? Its box is left exactly as it is — not stopped, not deleted — but the console stops watching it and the host tick stops waking it."))return;
    tr.remove();
    return;
  }
  /* Save: the whole table, as the file will read. The collector validates
     every line before anything moves and refuses with the line and the
     reason; a refusal leaves the operator's rows exactly as typed, beside
     the reason in the status line — the one moment the contents matter most. */
  var members=[].map.call(list.querySelectorAll("tr.rosrow"),function(tr){
    return {box:tr.querySelector('[data-k="box"]').value.trim(),
            agent:tr.querySelector('[data-k="agent"]').value,
            roles:[].map.call(tr.querySelectorAll('.rossel input:checked'),function(i){return i.value;}),
            from:tr.querySelector('[data-k="from"]').value.trim()};
  });
  return cmd("roster-set",{members:members}).then(function(r){if(r&&r.ok)openRoster();});
}
document.getElementById("filters").addEventListener("click",function(e){var b=e.target.closest(".fchip");if(!b)return;var f=b.dataset.f;floorFilter[f]=b.dataset.v;[].forEach.call(this.querySelectorAll('.fchip[data-f="'+f+'"]'),function(x){x.classList.toggle("on",x===b);});});
/* Pause/Resume is the box's crontab, not its power: the engine stops being
   woken, the box stays up and reachable. That is the reversible control an
   operator actually wants mid-incident. */
document.getElementById("a-pause").addEventListener("click",function(){
  if(!LIVE)return;var d=dataOf(BOX,ROOM);cmd(d.paused?"resume":"pause",{box:BOX});
});
document.getElementById("a-restart").addEventListener("click",function(){
  if(!LIVE)return;var box=BOX;
  restartClick(box,dataOf(BOX,ROOM));
});
document.getElementById("a-logs").addEventListener("click",function(){
  if(LIVE)return openLogs(BOX,"");
  var f=document.getElementById("dfeed");if(f)f.scrollTop=f.scrollHeight;
});
/* A message starts a real one-shot session of the box's own vendor CLI, fired
   from the host. It is refused for an unreachable box — there is nothing to
   run it. */
function sendMsg(){
  if(!LIVE)return;
  var inp=document.getElementById("c-in"),v=inp.value.trim();if(!v)return;
  var box=BOX;
  if(STATE==="offline"){setStatus("cannot message "+box+" — it is not running",true);return;}
  inp.value="";
  var f=document.getElementById("dfeed");
  if(f){var el=document.createElement("div");el.className="fev";el.innerHTML='<span class="ago">now</span><span style="color:#5fd6ff">📨 prompt</span><span style="color:#c7d4e4">'+esc(v.slice(0,42))+'</span>';f.insertBefore(el,f.firstChild);}
  cmd("message",{box:box,prompt:v});
}
document.getElementById("c-send").addEventListener("click",sendMsg);
document.getElementById("c-in").addEventListener("keydown",function(e){if(e.key==="Enter")sendMsg();e.stopPropagation();});
setInterval(function(){var c=document.getElementById("clock");if(c)c.textContent=clockStr();},1000);
setInterval(tickerEvent,1500);
refreshChrome();
/* ---- god-view floor interactions ---- */
var backBtn=document.getElementById("back");if(backBtn)backBtn.addEventListener("click",toFloor);
cv.addEventListener("mousedown",function(e){if(VIEW!=="floor")return;floorDrag=true;floorMoved=false;floorDragY=e.clientY;floorDragCam=floorCam;});
window.addEventListener("mouseup",function(){floorDrag=false;});
cv.addEventListener("mousemove",function(e){var r=cv.getBoundingClientRect();floorMouse.x=e.clientX-r.left;floorMouse.y=e.clientY-r.top;
  if(floorDrag){floorCam=floorDragCam-(e.clientY-floorDragY);floorCamTarget=floorCam;if(Math.abs(e.clientY-floorDragY)>4)floorMoved=true;}
  if(VIEW==="floor"){var over=false;for(var k=0;k<floorHits.length;k++){var c=floorHits[k];if(floorMouse.x>=c.x&&floorMouse.x<=c.x+c.w&&floorMouse.y>=c.y&&floorMouse.y<=c.y+c.h){over=true;break;}}cv.style.cursor=floorDrag?"grabbing":(over?"pointer":"grab");}else cv.style.cursor="default";});
cv.addEventListener("click",function(e){if(VIEW!=="floor"||floorMoved)return;var r=cv.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;for(var k=0;k<floorHits.length;k++){var c=floorHits[k];if(mx>=c.x&&mx<=c.x+c.w&&my>=c.y&&my<=c.y+c.h){focusUnit(c.i);return;}}});
/* Vertical: the grid overflows downward now, so the wheel's natural axis IS
   the scroll axis — deltaX still honoured for a trackpad held sideways. */
cv.addEventListener("wheel",function(e){if(VIEW!=="floor")return;e.preventDefault();floorCamTarget+=(e.deltaY||e.deltaX);},{passive:false});
document.addEventListener("keydown",function(e){
  if(e.key!=="Escape")return;
  /* Esc closes the log overlay first — otherwise it dismisses the room behind
     it and leaves the logs floating over the wrong view. */
  var rv=document.getElementById("regov");
  if(rv&&rv.style.display==="flex")return closeRegistries();
  var ov=document.getElementById("logov");
  if(ov&&ov.style.display==="flex")return closeLogs();
  if(VIEW==="room")toFloor();
});
document.body.className="floor";
resize();requestAnimationFrame(frame);
/* Ask for a snapshot immediately, then keep asking. A failure here is the
   normal case for `open index.html` and leaves the page in DEMO mode. */
pollFleet();setInterval(pollFleet,POLL_MS);
/* On the fleet poll's clock, and for one row: the VITALS summary. The editor
   never reads this cache — it re-reads on open — so a stale count here costs
   a row that is one poll old, never an edit applied to the wrong list. */
pollRegistries();setInterval(pollRegistries,POLL_MS);

/* ---- dev hook: the room renderer, addressable one unit at a time ----------
   dev/whiteboard.html lays every agent x room x state out as a single image so
   the art can be diffed tile-for-tile between commits. It needs the RENDERER,
   not the app, and it must not own a second copy of it — a whiteboard drawing
   its own robots would drift from the shipped ones the first time either
   changed, and then agree with a screenshot of nothing. So this draws with the
   same drawTarget the room view uses, into a canvas the caller owns, through
   borrowRoom — which is where "puts back every global it borrowed" actually
   lives, and is now shared with the god-view cell rather than being this
   hook's private habit. VIEW, the roster and the live poll never see it.
   Unused by index.html — it costs one property on window. */
window.FLOORDEV={W:DW,H:DH,AGENTS:["claude","codex","grok","kimi"],
  ROOMS:["builder","reviewer","triage"],STATES:["working","idle","suppressed","offline"],
  /* The floor camera (vertical, in px of grid overflow), for the browser
     walk. The camera eases per FRAME, not per second, so a fixed post-wheel
     wait covers almost no easing on a slow machine. The walk polls this
     instead of sleeping; it asserts by outcome either way. */
  cam:function(){return floorCam;},
  /* The floor header's stage counters, exactly as drawn — [text,colour] pairs.
     Canvas text is unreachable from the DOM, so a walk cannot read "0 SILENT"
     off the page any other way; the collector logging `0 silent` while the
     header shouted SILENT at three boxes is the regression this exists to
     make assertable (#203). Same ethos as cam(): a hook, not a second copy. */
  stages:function(){return stageCounts();},
  /* The filter scrim is painted on canvas, so the DOM can only say which chip
     is active. Return the boxes the shipped predicate currently leaves
     matched, not a test-side reconstruction of the classification. */
  matched:function(){return matchedFloorUnits().map(UNITID);},
  alert:function(box){var u=ROSTER.filter(function(x){return UNITID(x)===box;})[0];return u?alertOf(u):"";},
  alertData:function(d){return alertData(d);},
  fleetStateData:function(u,d){return fleetStateData(u,d);},
  /* The exact two rows drawCamCell appends. Browser coverage observes the
     canvas paint too; this hook gives missing and measured pairs stable values
     without reimplementing the conversion in the test. */
  camHeadroom:function(v){return camHeadroomRows(v);},
  /* The floor header's left-hand labels, exactly as painted. */
  header:function(){return floorHeaderLabels();},
  /* The SHIPPED confirm sentence for Restart AND the mode it authorises, over
     whatever unit data it is handed (#486). A confirm() dialog is unreadable
     to a walk until it has already been answered, and the thing that has to be
     asserted is not that a dialog appeared but that its WORDS match the path
     the collector will take — and now, that the mode put on the wire is the
     one those words promised, which is the whole of round 2's fix. Both come
     back from one call because they come from one evaluation.

     A hook, not a second copy: the reconstruction
     a test would otherwise write is exactly the independent threshold this
     round deleted. */
  restartPlan:function(box,d){return restartPlan(box,d);},
  /* ...and its other half: the sentence an operator is left with AFTER the
     action, over a reply this walk can name exactly. The escalation is
     disclosed twice — before the click and after it — so both sentences are
     assertable, and neither is reconstructed test-side. */
  cmdSay:function(action,results){return cmdSay(action,results);},
  /* ...and the failure sentence, which is the half N6 found mute. */
  cmdSayFail:function(action,results,why){return cmdSayFail(action,results,why);},
  /* camstats() — the portrait pipeline's stated behavior, checkable on a
     real fleet (same ethos as guides: a claim should be a lookable-at).
     buildsLastSec MUST read 0 with a stable roster — a deterministic still
     rebuilds only on first sight, state change or resize. buildEmaMs is
     what settles whether the old 14ms slow-mode cliff (#226 RC2) was ever
     being crossed, and what CAM_BUDGET should be tuned against. lastSwap
     and the beat grammar in drawCamCell are the declared glitch events the
     motion test is allowed to see artifacts on. */
  camstats:function(){
    var now=mnow(),n=0,sw={};
    for(var i=camBuiltAt.length-1;i>=0&&camBuiltAt[i]>now-1000;i--)n++;
    for(var k in camSwaps)sw[k]=camSwaps[k];
    return {buildEmaMs:camCost,buildsLastSec:n,
            cacheSize:Object.keys(camStills).length,lastSwap:sw};
  },
  /* render(dst,{agent,room,state,t,warm,flat}) */
  render:function(dst,o){
    borrowRoom(o,function(){
    var c=dst.getContext("2d"),W=dst.width,H=dst.height;
    c.setTransform(1,0,0,1,0,0);c.globalAlpha=1;c.globalCompositeOperation="source-over";c.filter="none";
    c.clearRect(0,0,W,H);c.imageSmoothingEnabled=true;c.imageSmoothingQuality="high";
    if(o.flat){c.drawImage(comp,0,0,DW,DH,0,0,W,H);}
    else{ /* the same chromatic split blit() ships, scaled — a tile has to be
             what an operator actually sees, fringing included */
      var dx=1.1*(W/DW);
      tintTo(tintR,comp,255,0,0);tintTo(tintG,comp,0,255,0);tintTo(tintB,comp,0,0,255);
      c.fillStyle="#000";c.fillRect(0,0,W,H);
      c.globalCompositeOperation="lighter";
      c.drawImage(tintG,0,0,DW,DH,0,0,W,H);
      c.drawImage(tintR,0,0,DW,DH,dx,0,W,H);
      c.drawImage(tintB,0,0,DW,DH,-dx,0,W,H);
      c.globalCompositeOperation="source-over";
    }
    });
  },
  /* renderMini(dst,{agent,room,state,box,t}) — the GOD-VIEW CELL, whole card
     and all, into a canvas the caller owns.
     The room view had a map and the cell had none, which is how a cell could
     carry a ghost sign, a colliding desk and a misplaced alert glyph through
     fifteen loops of polish: the roster only ever exercises seven of its
     thirty-six combinations, the other twenty-nine are unreachable in a
     healthy fleet, and reviewing them meant patching ROSTER by hand. So the
     cell is addressable too, by the same rule as the room — this draws with
     drawCamCell, the shipped one, and owns no art of its own.
     dst decides the scale: the cell is laid out at CAMREF and scaled to the
     canvas it is given, exactly as a device pixel ratio would. */
  MINI:{W:CAMREF.W,H:CAMREF.H},
  renderMini:function(dst,o){
    var sX=X,sdpr=dpr,sfl=camFills,ssw=camSwaps,sNow=Date.now;
    var k=dst.width/CAMREF.W;
    /* A dev render must be a pure function of its arguments. Three pieces of
       live state would otherwise leak in: the frame budget (forced open — a
       map needs every portrait THIS call, not when the app's ration next
       comes round), the swap ledger (the live floor's glitch history would
       replay into a golden), and the wall clock (the REC timer and IDLE-24H
       read Date.now, so two identical draws differed whenever they straddled
       a second boundary — pinning to BOOT also makes demo timers a constant,
       since demo session starts derive from the load-time clock). All three
       are swapped out and restored in a finally, so even a throwing build
       cannot leave the app rendering dev state. */
    try{
      X=dst.getContext("2d");dpr=k;
      camFills=-1e9;camSwaps={};
      Date.now=function(){return BOOT;};
      X.setTransform(k,0,0,k,0,0);X.globalAlpha=1;X.globalCompositeOperation="source-over";
      X.filter="none";X.textAlign="left";X.imageSmoothingEnabled=true;
      X.fillStyle="#03060d";X.fillRect(0,0,CAMREF.W,dst.height/k);
      drawCamCell(o.t||0,5,5,CAMREF.W-10,CAMREF.H-10,
                  {agent:o.agent,room:o.room,state:o.state,box:o.box});
    }finally{
      X=sX;dpr=sdpr;camFills=sfl;camSwaps=ssw;Date.now=sNow;
    }
  },
  /* The floor's real layout, for the browser walk: where each roster cell IS,
     under the camera as it stands. Mirroring the grid maths in the test broke
     every time the layout moved — this is the layout, so it cannot drift. */
  grid:function(){
    var g=floorGrid();g.camMax=Math.max(0,g.totalH-VH);g.cam=floorCam;g.n=ROSTER.length;
    g.cell=[];
    for(var i=0;i<ROSTER.length;i++){
      g.cell.push({i:i,x:g.mX+(i%g.cols)*(g.tw+g.gap),
                   y:g.mT+Math.floor(i/g.cols)*(g.th+g.gap)-floorCam});
    }
    return g;
  },
  /* guides(dst,{room}) — the declared layout, drawn over a tile this hook has
     already rendered. SIGN and BAYS were rules you had to hold in your head
     while looking at a picture; this is the picture with the rules on it, which
     is the difference between a stated layout and a documented intention. */
  guides:function(dst,o){
    var c=dst.getContext("2d"),k=dst.width/DW;
    c.save();c.setTransform(k,0,0,k,0,0);
    c.globalAlpha=1;c.globalCompositeOperation="source-over";c.filter="none";
    c.font="700 13px ui-monospace,monospace";c.textBaseline="top";c.textAlign="left";
    var box=function(x,y,w,h,col,lab){
      c.strokeStyle=col;c.lineWidth=2;c.setLineDash([7,5]);c.strokeRect(x,y,w,h);c.setLineDash([]);
      var tw=c.measureText(lab).width;
      c.fillStyle="rgba(0,0,0,0.65)";c.fillRect(x+3,y+3,tw+8,17);
      c.fillStyle=col;c.fillText(lab,x+7,y+5);
    };
    box(SIGN.x,SIGN.y,SIGN.w,SIGN.h,"rgba(247,189,78,0.95)","sign");
    var B=BAYS[o.room];
    if(B){box(B.L[0],B.L[1],B.L[2],B.L[3],"rgba(120,205,255,0.95)","bay L");
          box(B.R[0],B.R[1],B.R[2],B.R[3],"rgba(120,205,255,0.95)","bay R");}
    var U=LAYOUT.unit;box(U[1],U[2],U[3],U[4],"rgba(255,140,60,0.95)",U[0]);
    var N=LAYOUT.near;box(N[1],N[2],N[3],N[4],"rgba(255,120,190,0.95)",N[0]);
    (LAYOUT.nearSide[o.room]||[]).forEach(function(z){box(z[1],z[2],z[3],z[4],"rgba(255,120,190,0.95)",z[0]);});
    LAYOUT.keep.forEach(function(z){box(z[1],z[2],z[3],z[4],"rgba(255,90,80,0.9)",z[0]);});
    (LAYOUT.deck[o.room]||[]).forEach(function(z){box(z[1],z[2],z[3],z[4],"rgba(110,240,170,0.9)",z[0]);});
    LAYOUT.fixed.all.concat(LAYOUT.fixed[o.room]||[]).forEach(function(z){box(z[1],z[2],z[3],z[4],"rgba(180,160,255,0.9)",z[0]);});
    c.restore();
  },
  /* unitBox({agent,state}) — where a unit actually reaches, in room
     coordinates, measured off the drawn sprite rather than estimated from it.
     LAYOUT's keep-clear column is the union of these across every vendor and
     state, and this is how it is re-derived when a robot changes shape. The
     first hand-written version of that rectangle was 220 wide and wrong twice
     over: it crossed into the builder's left bay AND under the pegboard, so a
     rule invented to stop collisions was itself colliding. */
  unitBox:function(o){
    return borrowRoom({agent:o.agent,room:o.room||"builder",state:o.state||"working",t:o.t||0,warm:0},function(){
      var sp=lastAnchors&&lastAnchors.sprite;if(!sp)return null;
      var d=RB.getImageData(0,0,RW,RH).data,x0=RW,y0=RH,x1=0,y1=0,hit=false;
      for(var y=0;y<RH;y++)for(var x=0;x<RW;x++){
        if(d[(y*RW+x)*4+3]>24){hit=true;if(x<x0)x0=x;if(x>x1)x1=x;if(y<y0)y0=y;if(y>y1)y1=y;}
      }
      if(!hit)return null;
      return {x:sp.x+x0*sp.s,y:sp.y+y0*sp.s,w:(x1-x0)*sp.s,h:(y1-y0)*sp.s,
              head:lastAnchors.head,hand:lastAnchors.hand,feet:lastAnchors.feet};
    });
  },
  /* layout() — the declared rectangles, for a tool that wants to test them
     rather than draw them. Bays come out named so a report can say which. */
  layout:function(){
    var bay=function(k,r){return [k+" bay",BAYS[r][k==="L"?"L":"R"][0],BAYS[r][k][1],BAYS[r][k][2],BAYS[r][k][3]];};
    return {unit:LAYOUT.unit,near:LAYOUT.near,nearSide:LAYOUT.nearSide,keep:LAYOUT.keep,deck:LAYOUT.deck,fixed:LAYOUT.fixed,sign:["sign",SIGN.x,SIGN.y,SIGN.w,SIGN.h],
            bayL:{builder:bay("L","builder"),reviewer:bay("L","reviewer"),triage:bay("L","triage")},
            bayR:{builder:bay("R","builder"),reviewer:bay("R","reviewer"),triage:bay("R","triage")}};
  },
  /* renderSolo(dst,{agent,state,t,room}) — the unit ALONE, full body, on a
     deliberately mute studio stage: grey wall pool for silhouette separation,
     a floor seam, contact shadows under the returned feet, nothing else. For
     judging a robot's anatomy without its room. Drawn through buildRobo on a
     supersampled trio (the portrait path's trick), never a second copy. */
  renderSolo:function(dst,o){
    var sa=AGENT,sr=ROOM,st2=STATE,sbp=beaconPulse;
    var sRo=robo,sRB=RB,sEm=remit,sRE=RE,sRi=rrim,sRR=RR,sSS=SS;
    try{
      AGENT=o.agent;ROOM=o.room||"builder";STATE=o.state;beaconPulse=0.65;
      var K=Math.max(1,Math.min(3,(dst.height||1200)/RH));
      robo=oc(Math.round(RW*K),Math.round(RH*K));RB=robo.getContext("2d");
      remit=oc(robo.width,robo.height);RE=remit.getContext("2d");
      rrim=oc(robo.width,robo.height);RR=rrim.getContext("2d");
      SS=K;
      var info=buildRobo(o.t||0,o.state);
      // frame off the drawn alpha, not an estimate (the unitBox lesson)
      var pd=RB.getImageData(0,0,robo.width,robo.height).data,
          x0=robo.width,y0=robo.height,x1=0,y1=0;
      for(var y=0;y<robo.height;y+=2)for(var x=0;x<robo.width;x+=2){
        if(pd[(y*robo.width+x)*4+3]>24){if(x<x0)x0=x;if(x>x1)x1=x;if(y<y0)y0=y;if(y>y1)y1=y;}}
      var padU=26, fy=0;
      for(var fi=0;fi<(info.feet||[]).length;fi++)if(info.feet[fi].y>fy)fy=info.feet[fi].y;
      // the bottom pad is the floor's whole depth — a plane needs room to recede
      var cx0=x0/K-padU, cy0=y0/K-padU*1.3, cx1=x1/K+padU, cy1=Math.max(y1/K,fy)+padU*2.6;
      var W2=dst.width,H2=dst.height,c=dst.getContext("2d");
      var sc2=Math.min(W2/(cx1-cx0),H2/(cy1-cy0));
      var ox=(W2-(cx1-cx0)*sc2)/2, oy=(H2-(cy1-cy0)*sc2)/2;
      function mx2(u){return ox+(u-cx0)*sc2;} function my2(u){return oy+(u-cy0)*sc2;}
      c.setTransform(1,0,0,1,0,0);c.globalAlpha=1;c.globalCompositeOperation="source-over";c.filter="none";
      c.imageSmoothingEnabled=true;c.imageSmoothingQuality="high";
      /* the stage: the wall/floor junction sits BEHIND the unit, not under
         its toes — the floor plane runs on past the feet in both directions,
         so the figure stands IN the room, never on a ledge lip */
      var fyd=my2(fy), jy=fyd-Math.min(54,(H2-fyd)*0.5);
      /* the backdrop sits LOW: the unit's own darks must clear it, and the
         silhouette separates against the wall pools, never by brightening
         the figure */
      var wg=c.createLinearGradient(0,0,0,jy);
      wg.addColorStop(0,"#070a10");wg.addColorStop(1,"#03050a");
      c.fillStyle=wg;c.fillRect(0,0,W2,jy);
      /* a CYCLORAMA, not a backdrop edge: the floor starts at the wall's own
         value, and the value story runs WALL DARK, FLOOR LIT — the key's
         spill lands on the deck around the figure, clearly above the wall's
         base, and falls off toward the bottom corners. The floor's ambient
         never drops below the stance shadow's core: darkest floor stays
         under the feet, and nothing on the deck goes near-black. */
      var fg=c.createLinearGradient(0,jy,0,H2);
      fg.addColorStop(0,"#03050a");fg.addColorStop(0.2,"#131b2a");fg.addColorStop(1,"#0c1320");
      c.fillStyle=fg;c.fillRect(0,jy,W2,H2-jy);
      /* the wall pools ride OVER the junction, full height: light that
         stops dead at a cyc's base re-draws the seam the blend removed.
         They stay BELOW the floor's key spill — the wall must recede. */
      var pool=c.createRadialGradient(W2*0.44,H2*0.36,H2*0.06,W2*0.44,H2*0.36,H2*0.52);
      pool.addColorStop(0,"rgba(126,146,176,0.09)");pool.addColorStop(1,"rgba(126,146,176,0)");
      c.fillStyle=pool;c.fillRect(0,0,W2,H2);
      /* second pool behind the FILL side: the dark flank reads against
         lifted wall — hip to ankle needs grey behind it */
      var pool2=c.createRadialGradient(W2*0.63,H2*0.60,H2*0.05,W2*0.63,H2*0.60,H2*0.52);
      pool2.addColorStop(0,"rgba(126,146,176,0.10)");pool2.addColorStop(1,"rgba(126,146,176,0)");
      c.fillStyle=pool2;c.fillRect(0,0,W2,H2);
      /* the floor must read as a PLANE under ONE lamp: the grey spill lands
         up-LEFT of the unit (where the key is), a faint transverse joint
         recedes, and the figure answers the spill with a cast shadow thrown
         down-RIGHT. Still mute — grey light on grey deck. */
      /* the spill, unclipped: it curls a little way up the cyc base, which
         is what a pool of lamp light does where wall becomes floor */
      var plx=W2*0.35, ply=jy+4;
      var fpool=c.createRadialGradient(plx,ply,2,plx,ply,W2*0.62);
      fpool.addColorStop(0,"rgba(150,170,198,0.20)");fpool.addColorStop(0.55,"rgba(150,170,198,0.09)");fpool.addColorStop(1,"rgba(150,170,198,0)");
      c.save();c.translate(plx,ply);c.scale(1,0.42);c.translate(-plx,-ply);
      c.fillStyle=fpool;c.beginPath();c.arc(plx,ply,W2*0.62,0,7);c.fill();
      c.restore();
      // one barely-there transverse joint — more and the floor reads as bands
      c.fillStyle="rgba(140,162,192,0.03)";c.fillRect(0,jy+(H2-jy)*0.34,W2,1);
      if((info.feet||[]).length){
        var fmn=1e9,fmx=-1e9;info.feet.forEach(function(f2){var xx=mx2(f2.x);if(xx<fmn)fmn=xx;if(xx>fmx)fmx=xx;});
        var scx=(fmn+fmx)/2, shw=(fmx-fmn)/2+info.feet[0].w*sc2;
        // unclipped: on a cyc the cast grazes the wall base — a shadow that
        // stops dead at jy cuts the very line the blend band removed
        c.save();c.translate(scx,fyd+3);c.rotate(0.3);c.scale(1,0.3);
        var csg=c.createRadialGradient(shw*0.9,0,2,shw*0.9,0,shw*2.6);
        csg.addColorStop(0,"rgba(0,0,0,0.3)");csg.addColorStop(0.55,"rgba(0,0,0,0.14)");csg.addColorStop(1,"rgba(0,0,0,0)");
        c.fillStyle=csg;c.beginPath();c.arc(shw*0.9,0,shw*2.6,0,7);c.fill();
        c.restore();
        /* stance core: one ellipse under the whole stance, feet AND the gap.
           SOFT — a shadow is dimmed floor, never a hole: its core must hold
           within ~2x of the adjacent lit deck, so the alpha stays under 0.5
           and the falloff runs wide */
        var stg=c.createRadialGradient(scx,fyd+3,2,scx,fyd+3,shw*1.3);
        stg.addColorStop(0,"rgba(0,0,0,0.38)");stg.addColorStop(0.55,"rgba(0,0,0,0.2)");stg.addColorStop(1,"rgba(0,0,0,0)");
        c.save();c.translate(scx,fyd+3);c.scale(1,0.3);c.translate(-scx,-(fyd+3));
        c.fillStyle=stg;c.beginPath();c.arc(scx,fyd+3,shw*1.3,0,7);c.fill();c.restore();}
      (info.feet||[]).forEach(function(f2){
        // pooled shadow per foot — EACH foot owns one, same weight, tight
        // enough that the pair never merges into the stance core's gradient
        var fx2=mx2(f2.x),fw2=f2.w*sc2;
        var sg2=c.createRadialGradient(fx2,fyd+3,1,fx2,fyd+3,fw2*1.5);
        sg2.addColorStop(0,"rgba(0,0,0,0.5)");sg2.addColorStop(0.6,"rgba(0,0,0,0.26)");sg2.addColorStop(1,"rgba(0,0,0,0)");
        c.save();c.translate(fx2,fyd+3);c.scale(1,0.4);c.translate(-fx2,-(fyd+3));
        c.fillStyle=sg2;c.beginPath();c.arc(fx2,fyd+3,fw2*1.5,0,7);c.fill();c.restore();
        // contact occlusion: a tight dark pinch under each toe TIP — the
        // broad pool says "near the floor", only this says "on it"
        (f2.toes||[]).forEach(function(tx5){
          var txd=mx2(tx5), tr=Math.max(3,sc2*6.5), tcy=fyd+2.5;
          var tg=c.createRadialGradient(txd,tcy,0.5,txd,tcy,tr);
          tg.addColorStop(0,"rgba(0,0,0,0.9)");tg.addColorStop(0.55,"rgba(0,0,0,0.5)");tg.addColorStop(1,"rgba(0,0,0,0)");
          c.save();c.translate(txd,tcy);c.scale(1,0.45);c.translate(-txd,-tcy);
          c.fillStyle=tg;c.beginPath();c.arc(txd,tcy,tr,0,7);c.fill();c.restore();});});
      // sprite: colour, then rim, then the emissive taps — the portrait recipe
      var sxp=cx0*K,syp=cy0*K,swp=(cx1-cx0)*K,shp=(cy1-cy0)*K;
      var dxp=ox,dyp=oy,dwp=(cx1-cx0)*sc2,dhp=(cy1-cy0)*sc2;
      var off2=o.state==="offline";
      if(off2)c.filter="saturate(0.45) brightness(0.88)";
      c.drawImage(robo,sxp,syp,swp,shp,dxp,dyp,dwp,dhp);
      c.filter="none";c.globalCompositeOperation="lighter";
      c.globalAlpha=off2?0.4:0.9;c.drawImage(rrim,sxp,syp,swp,shp,dxp,dyp,dwp,dhp);
      /* bloom taps stay TIGHT: wide taps fog every hard edge near an
         emissive — optics are points of light, never weather */
      var bl2=Math.max(2,Math.round(W2/240));
      c.globalAlpha=0.55;c.filter="blur("+bl2+"px)";c.drawImage(remit,sxp,syp,swp,shp,dxp,dyp,dwp,dhp);
      c.globalAlpha=0.45;c.filter="blur("+(bl2*2.5)+"px)";c.drawImage(remit,sxp,syp,swp,shp,dxp,dyp,dwp,dhp);
      c.globalAlpha=off2?0.5:0.9;c.filter="none";c.drawImage(remit,sxp,syp,swp,shp,dxp,dyp,dwp,dhp);
      c.globalCompositeOperation="source-over";c.globalAlpha=1;
      return {box:{x:cx0,y:cy0,w:cx1-cx0,h:cy1-cy0},feet:info.feet};
    }finally{
      robo=sRo;RB=sRB;remit=sEm;RE=sRE;rrim=sRi;RR=sRR;SS=sSS;
      AGENT=sa;ROOM=sr;STATE=st2;beaconPulse=sbp;
    }
  },
  /* Stop the hidden app loop painting behind a map. */
  pause:function(){devPaused=true;}};
})();
