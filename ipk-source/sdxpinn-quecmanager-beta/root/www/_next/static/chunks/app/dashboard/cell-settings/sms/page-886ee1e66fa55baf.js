(self.webpackChunk_N_E=self.webpackChunk_N_E||[]).push([[2959],{98910:function(e,t,r){Promise.resolve().then(r.bind(r,26678))},26678:function(e,t,r){"use strict";r.r(t),r.d(t,{default:function(){return v}});var n=r(20881),a=r(64149),s=r(92093);let i=(0,s.Z)("LoaderCircle",[["path",{d:"M21 12a9 9 0 1 1-6.219-8.56",key:"13zald"}]]);var l=r(75526);let o=(0,s.Z)("RotateCw",[["path",{d:"M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8",key:"1p45f6"}],["path",{d:"M21 3v5h-5",key:"1q7to0"}]]);var d=r(36306),c=r(94920),u=r(30214),f=r(24004),m=r(835),h=r(78580),x=r(47657),p=r(75577),g=r(33335),v=()=>{let[e,t]=(0,a.useState)([]),[r,s]=(0,a.useState)(!1),[v,b]=(0,a.useState)([]),[y,j]=(0,a.useState)({phoneNumber:"",message:""}),N=async e=>{try{let t=await fetch("/cgi-bin/atinout_handler.sh",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:"command=".concat(encodeURIComponent(e))});return await t.json()}catch(e){throw console.error("AT command failed:",e),e}},w=e=>{let t=[],r=e.split("\n"),n=null;for(let e=0;e<r.length;e++){let a=r[e].trim();if(a&&"OK"!==a&&'AT+CMGL="ALL"'!==a){if(a.startsWith("+CMGL:")){n&&n.message&&t.push(n);let e=a.match(/\+CMGL:\s*(\d+),"([^"]*?)","([^"]*?)",,"([^"]*?)"/);if(e){let[t,r]=e[4].replace("+32","").split(","),[a,s,i]=t.split("/"),l="20".concat(a,"-").concat(s,"-").concat(i);n={index:e[1],status:e[2],sender:e[3],date:l,time:r,message:""}}}else n&&(n.message="".concat(n.message||"").concat(n.message?"\n":"").concat(a))}}return n&&n.message&&t.push(n),t},k=async()=>{s(!0);try{let e;await N("AT+CMGF=1");let r=await N('AT+CMGL="ALL"');if("string"==typeof r)e=r;else if(null==r?void 0:r.result)e=r.result;else if(null==r?void 0:r.output)e=r.output;else throw Error("No valid data received");let n=w(e);t(n)}catch(e){console.error("Failed to refresh SMS:",e),t([])}finally{s(!1)}},C=e=>{b(t=>t.includes(e)?t.filter(t=>t!==e):[...t,e])},S=async()=>{if(v.length)try{for(let e of v)await N("AT+CMGD=".concat(e));await k(),b([])}catch(e){console.error("Failed to delete messages:",e)}},R=async()=>{let{phoneNumber:e,message:t}=y;if(!e||!t){alert("Please enter both phone number and message");return}try{await N('AT+CMGS="'.concat(e,'"')),await N("".concat(t,"\x1a")),j({phoneNumber:"",message:""}),await k()}catch(e){console.error("Failed to send SMS:",e)}};return(0,a.useEffect)(()=>{k()},[]),(0,n.jsxs)("div",{className:"grid gap-6",children:[(0,n.jsxs)(c.Zb,{className:"w-full max-w-screen",children:[(0,n.jsxs)(c.Ol,{children:[(0,n.jsx)(c.ll,{children:"SMS Inbox"}),(0,n.jsx)(c.SZ,{children:(0,n.jsxs)("div",{className:"flex justify-between items-center",children:[(0,n.jsx)("span",{children:"View and manage SMS messages"}),(0,n.jsxs)("div",{className:"flex items-center space-x-1.5",children:[(0,n.jsx)(m.X,{checked:v.length===e.length,onCheckedChange:t=>{b(t?e.map(e=>e.index):[])}}),(0,n.jsx)("span",{className:"text-sm",children:"Select All"})]})]})})]}),(0,n.jsx)(c.aY,{children:(0,n.jsx)(f.x,{className:"h-[400px] w-full xs:max-w-xs p-4 grid",children:r?(0,n.jsxs)("div",{className:"flex flex-col items-center justify-center py-8",children:[(0,n.jsx)(i,{className:"h-8 w-8 animate-spin"}),(0,n.jsx)("p",{className:"mt-2",children:"Loading messages..."})]}):0===e.length?(0,n.jsx)("p",{className:"text-center py-8 text-muted-foreground",children:"No messages found"}):e.map(e=>(0,n.jsxs)(u.Vq,{children:[(0,n.jsx)(u.hg,{className:"w-full",children:(0,n.jsxs)(c.Zb,{className:"my-2 dark:hover:bg-slate-900 hover:bg-slate-100",children:[(0,n.jsxs)(c.Ol,{children:[(0,n.jsxs)("div",{className:"flex justify-between items-center",children:[(0,n.jsx)(c.ll,{children:e.sender}),(0,n.jsxs)("div",{className:"flex items-center space-x-2",onClick:e=>e.stopPropagation(),children:[(0,n.jsx)("p",{className:"text-muted-foreground font-medium text-xs",children:e.index}),(0,n.jsx)(m.X,{checked:v.includes(e.index),onCheckedChange:()=>C(e.index)})]})]}),(0,n.jsxs)(c.SZ,{className:"text-left",children:[e.date," at ",e.time]})]}),(0,n.jsx)(c.aY,{children:(0,n.jsx)("p",{className:"line-clamp-3",children:e.message})})]})}),(0,n.jsxs)(u.cZ,{children:[(0,n.jsxs)(u.fK,{children:[(0,n.jsx)(u.$N,{children:e.sender}),(0,n.jsxs)(u.Be,{children:[e.date," at ",e.time]})]}),(0,n.jsx)("p",{children:e.message}),(0,n.jsx)(x.Z,{className:"my-2"}),(0,n.jsx)(p.g,{placeholder:"Reply to ".concat(e.sender,"..."),className:"h-24",readOnly:!0}),(0,n.jsx)("div",{className:"flex justify-end",children:(0,n.jsxs)(h.z,{onClick:R,disabled:!0,children:[(0,n.jsx)(l.Z,{className:"h-4 w-4 mr-2"}),"Send"]})})]})]},e.index))})}),(0,n.jsx)(c.eW,{className:"border-t py-4",children:(0,n.jsxs)("div",{className:"flex w-full justify-between items-center",children:[(0,n.jsxs)(h.z,{variant:"outline",onClick:k,disabled:r,children:[(0,n.jsx)(o,{className:"h-4 w-4"}),"Refresh"]}),(0,n.jsxs)(h.z,{variant:"destructive",onClick:S,disabled:0===v.length,children:[(0,n.jsx)(d.Z,{className:"h-4 w-4"}),"Delete Selected"]})]})})]}),(0,n.jsxs)(c.Zb,{children:[(0,n.jsxs)(c.Ol,{children:[(0,n.jsx)(c.ll,{children:"Send SMS"}),(0,n.jsx)(c.SZ,{children:"Send a new SMS message"})]}),(0,n.jsx)(c.aY,{children:(0,n.jsxs)("div",{className:"grid gap-6",children:[(0,n.jsx)(g.I,{placeholder:"Recipient Number",value:y.phoneNumber,onChange:e=>j(t=>({...t,phoneNumber:e.target.value})),readOnly:!0}),(0,n.jsx)(p.g,{placeholder:"Sending message is still in development...",className:"h-32",value:y.message,onChange:e=>j(t=>({...t,message:e.target.value})),readOnly:!0}),(0,n.jsx)("div",{className:"flex justify-end",children:(0,n.jsxs)(h.z,{onClick:R,disabled:!0,children:[(0,n.jsx)(l.Z,{className:"h-4 w-4"}),"Send"]})})]})})]})]})}},78580:function(e,t,r){"use strict";r.d(t,{d:function(){return o},z:function(){return d}});var n=r(20881),a=r(64149),s=r(54098),i=r(20116),l=r(90270);let o=(0,i.j)("inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0",{variants:{variant:{default:"bg-primary text-primary-foreground shadow hover:bg-primary/90",destructive:"bg-destructive text-destructive-foreground shadow-sm hover:bg-destructive/90",outline:"border border-input bg-background shadow-sm hover:bg-accent hover:text-accent-foreground",secondary:"bg-secondary text-secondary-foreground shadow-sm hover:bg-secondary/80",ghost:"hover:bg-accent hover:text-accent-foreground",link:"text-primary underline-offset-4 hover:underline"},size:{default:"h-9 px-4 py-2",sm:"h-8 rounded-md px-3 text-xs",lg:"h-10 rounded-md px-8",icon:"h-9 w-9"}},defaultVariants:{variant:"default",size:"default"}}),d=a.forwardRef((e,t)=>{let{className:r,variant:a,size:i,asChild:d=!1,...c}=e,u=d?s.g7:"button";return(0,n.jsx)(u,{className:(0,l.cn)(o({variant:a,size:i,className:r})),ref:t,...c})});d.displayName="Button"},94920:function(e,t,r){"use strict";r.d(t,{Ol:function(){return l},SZ:function(){return d},Zb:function(){return i},aY:function(){return c},eW:function(){return u},ll:function(){return o}});var n=r(20881),a=r(64149),s=r(90270);let i=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)("div",{ref:t,className:(0,s.cn)("rounded-xl border bg-card text-card-foreground shadow",r),...a})});i.displayName="Card";let l=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)("div",{ref:t,className:(0,s.cn)("flex flex-col space-y-1.5 p-6",r),...a})});l.displayName="CardHeader";let o=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)("h3",{ref:t,className:(0,s.cn)("font-semibold leading-none tracking-tight",r),...a})});o.displayName="CardTitle";let d=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)("p",{ref:t,className:(0,s.cn)("text-sm text-muted-foreground",r),...a})});d.displayName="CardDescription";let c=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)("div",{ref:t,className:(0,s.cn)("p-6 pt-0",r),...a})});c.displayName="CardContent";let u=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)("div",{ref:t,className:(0,s.cn)("flex items-center p-6 pt-0",r),...a})});u.displayName="CardFooter"},835:function(e,t,r){"use strict";r.d(t,{X:function(){return o}});var n=r(20881),a=r(64149),s=r(17533),i=r(35935),l=r(90270);let o=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)(s.fC,{ref:t,className:(0,l.cn)("peer h-4 w-4 shrink-0 rounded-sm border border-primary shadow focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 data-[state=checked]:bg-primary data-[state=checked]:text-primary-foreground",r),...a,children:(0,n.jsx)(s.z$,{className:(0,l.cn)("flex items-center justify-center text-current"),children:(0,n.jsx)(i.nQG,{className:"h-4 w-4"})})})});o.displayName=s.fC.displayName},30214:function(e,t,r){"use strict";r.d(t,{$N:function(){return x},Be:function(){return p},GG:function(){return u},Vq:function(){return o},cZ:function(){return m},fK:function(){return h},hg:function(){return d}});var n=r(20881),a=r(64149),s=r(14491),i=r(35935),l=r(90270);let o=s.fC,d=s.xz,c=s.h_,u=s.x8,f=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)(s.aV,{ref:t,className:(0,l.cn)("fixed inset-0 z-50 bg-black/80  data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0",r),...a})});f.displayName=s.aV.displayName;let m=a.forwardRef((e,t)=>{let{className:r,children:a,...o}=e;return(0,n.jsxs)(c,{children:[(0,n.jsx)(f,{}),(0,n.jsxs)(s.VY,{ref:t,className:(0,l.cn)("fixed left-[50%] top-[50%] z-50 grid w-full max-w-lg translate-x-[-50%] translate-y-[-50%] gap-4 border bg-background p-6 shadow-lg duration-200 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[state=closed]:slide-out-to-left-1/2 data-[state=closed]:slide-out-to-top-[48%] data-[state=open]:slide-in-from-left-1/2 data-[state=open]:slide-in-from-top-[48%] sm:rounded-lg",r),...o,children:[a,(0,n.jsxs)(s.x8,{className:"absolute right-4 top-4 rounded-sm opacity-70 ring-offset-background transition-opacity hover:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2 disabled:pointer-events-none data-[state=open]:bg-accent data-[state=open]:text-muted-foreground",children:[(0,n.jsx)(i.Pxu,{className:"h-4 w-4"}),(0,n.jsx)("span",{className:"sr-only",children:"Close"})]})]})]})});m.displayName=s.VY.displayName;let h=e=>{let{className:t,...r}=e;return(0,n.jsx)("div",{className:(0,l.cn)("flex flex-col space-y-1.5 text-center sm:text-left",t),...r})};h.displayName="DialogHeader";let x=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)(s.Dx,{ref:t,className:(0,l.cn)("text-lg font-semibold leading-none tracking-tight",r),...a})});x.displayName=s.Dx.displayName;let p=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)(s.dk,{ref:t,className:(0,l.cn)("text-sm text-muted-foreground",r),...a})});p.displayName=s.dk.displayName},33335:function(e,t,r){"use strict";r.d(t,{I:function(){return i}});var n=r(20881),a=r(64149),s=r(90270);let i=a.forwardRef((e,t)=>{let{className:r,type:a,...i}=e;return(0,n.jsx)("input",{type:a,className:(0,s.cn)("flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm transition-colors file:border-0 file:bg-transparent file:text-sm file:font-medium file:text-foreground placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50",r),ref:t,...i})});i.displayName="Input"},24004:function(e,t,r){"use strict";r.d(t,{B:function(){return o},x:function(){return l}});var n=r(20881),a=r(64149),s=r(82310),i=r(90270);let l=a.forwardRef((e,t)=>{let{className:r,children:a,...l}=e;return(0,n.jsxs)(s.fC,{ref:t,className:(0,i.cn)("relative overflow-hidden",r),...l,children:[(0,n.jsx)(s.l_,{className:"h-full w-full rounded-[inherit]",children:a}),(0,n.jsx)(o,{}),(0,n.jsx)(s.Ns,{})]})});l.displayName=s.fC.displayName;let o=a.forwardRef((e,t)=>{let{className:r,orientation:a="vertical",...l}=e;return(0,n.jsx)(s.gb,{ref:t,orientation:a,className:(0,i.cn)("flex touch-none select-none transition-colors","vertical"===a&&"h-full w-2.5 border-l border-l-transparent p-[1px]","horizontal"===a&&"h-2.5 flex-col border-t border-t-transparent p-[1px]",r),...l,children:(0,n.jsx)(s.q4,{className:"relative flex-1 rounded-full bg-border"})})});o.displayName=s.gb.displayName},47657:function(e,t,r){"use strict";r.d(t,{Z:function(){return l}});var n=r(20881),a=r(64149),s=r(48897),i=r(90270);let l=a.forwardRef((e,t)=>{let{className:r,orientation:a="horizontal",decorative:l=!0,...o}=e;return(0,n.jsx)(s.f,{ref:t,decorative:l,orientation:a,className:(0,i.cn)("shrink-0 bg-border","horizontal"===a?"h-[1px] w-full":"h-full w-[1px]",r),...o})});l.displayName=s.f.displayName},75577:function(e,t,r){"use strict";r.d(t,{g:function(){return i}});var n=r(20881),a=r(64149),s=r(90270);let i=a.forwardRef((e,t)=>{let{className:r,...a}=e;return(0,n.jsx)("textarea",{className:(0,s.cn)("flex min-h-[60px] w-full rounded-md border border-input bg-transparent px-3 py-2 text-base shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",r),ref:t,...a})});i.displayName="Textarea"},90270:function(e,t,r){"use strict";r.d(t,{cn:function(){return s}});var n=r(33958),a=r(61779);function s(){for(var e=arguments.length,t=Array(e),r=0;r<e;r++)t[r]=arguments[r];return(0,a.m6)((0,n.W)(t))}},92093:function(e,t,r){"use strict";r.d(t,{Z:function(){return o}});var n=r(64149);let a=e=>e.replace(/([a-z0-9])([A-Z])/g,"$1-$2").toLowerCase(),s=function(){for(var e=arguments.length,t=Array(e),r=0;r<e;r++)t[r]=arguments[r];return t.filter((e,t,r)=>!!e&&r.indexOf(e)===t).join(" ")};var i={xmlns:"http://www.w3.org/2000/svg",width:24,height:24,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:2,strokeLinecap:"round",strokeLinejoin:"round"};let l=(0,n.forwardRef)((e,t)=>{let{color:r="currentColor",size:a=24,strokeWidth:l=2,absoluteStrokeWidth:o,className:d="",children:c,iconNode:u,...f}=e;return(0,n.createElement)("svg",{ref:t,...i,width:a,height:a,stroke:r,strokeWidth:o?24*Number(l)/Number(a):l,className:s("lucide",d),...f},[...u.map(e=>{let[t,r]=e;return(0,n.createElement)(t,r)}),...Array.isArray(c)?c:[c]])}),o=(e,t)=>{let r=(0,n.forwardRef)((r,i)=>{let{className:o,...d}=r;return(0,n.createElement)(l,{ref:i,iconNode:t,className:s("lucide-".concat(a(e)),o),...d})});return r.displayName="".concat(e),r}},75526:function(e,t,r){"use strict";r.d(t,{Z:function(){return n}});let n=(0,r(92093).Z)("Send",[["path",{d:"M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z",key:"1ffxy3"}],["path",{d:"m21.854 2.147-10.94 10.939",key:"12cjpa"}]])},36306:function(e,t,r){"use strict";r.d(t,{Z:function(){return n}});let n=(0,r(92093).Z)("Trash2",[["path",{d:"M3 6h18",key:"d0wm0j"}],["path",{d:"M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6",key:"4alrt4"}],["path",{d:"M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2",key:"v07s0e"}],["line",{x1:"10",x2:"10",y1:"11",y2:"17",key:"1uufr5"}],["line",{x1:"14",x2:"14",y1:"11",y2:"17",key:"xtxkd"}]])},17533:function(e,t,r){"use strict";r.d(t,{fC:function(){return k},z$:function(){return C}});var n=r(64149),a=r(83954),s=r(74873),i=r(64433),l=r(45306),o=r(32437),d=r(73452),c=r(45485),u=r(79442),f=r(20881),m="Checkbox",[h,x]=(0,s.b)(m),[p,g]=h(m),v=n.forwardRef((e,t)=>{let{__scopeCheckbox:r,name:s,checked:o,defaultChecked:d,required:c,disabled:m,value:h="on",onCheckedChange:x,form:g,...v}=e,[b,y]=n.useState(null),k=(0,a.e)(t,e=>y(e)),C=n.useRef(!1),S=!b||g||!!b.closest("form"),[R=!1,z]=(0,l.T)({prop:o,defaultProp:d,onChange:x}),M=n.useRef(R);return n.useEffect(()=>{let e=null==b?void 0:b.form;if(e){let t=()=>z(M.current);return e.addEventListener("reset",t),()=>e.removeEventListener("reset",t)}},[b,z]),(0,f.jsxs)(p,{scope:r,state:R,disabled:m,children:[(0,f.jsx)(u.WV.button,{type:"button",role:"checkbox","aria-checked":N(R)?"mixed":R,"aria-required":c,"data-state":w(R),"data-disabled":m?"":void 0,disabled:m,value:h,...v,ref:k,onKeyDown:(0,i.M)(e.onKeyDown,e=>{"Enter"===e.key&&e.preventDefault()}),onClick:(0,i.M)(e.onClick,e=>{z(e=>!!N(e)||!e),S&&(C.current=e.isPropagationStopped(),C.current||e.stopPropagation())})}),S&&(0,f.jsx)(j,{control:b,bubbles:!C.current,name:s,value:h,checked:R,required:c,disabled:m,form:g,style:{transform:"translateX(-100%)"},defaultChecked:!N(d)&&d})]})});v.displayName=m;var b="CheckboxIndicator",y=n.forwardRef((e,t)=>{let{__scopeCheckbox:r,forceMount:n,...a}=e,s=g(b,r);return(0,f.jsx)(c.z,{present:n||N(s.state)||!0===s.state,children:(0,f.jsx)(u.WV.span,{"data-state":w(s.state),"data-disabled":s.disabled?"":void 0,...a,ref:t,style:{pointerEvents:"none",...e.style}})})});y.displayName=b;var j=e=>{let{control:t,checked:r,bubbles:a=!0,defaultChecked:s,...i}=e,l=n.useRef(null),c=(0,o.D)(r),u=(0,d.t)(t);n.useEffect(()=>{let e=l.current,t=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"checked").set;if(c!==r&&t){let n=new Event("click",{bubbles:a});e.indeterminate=N(r),t.call(e,!N(r)&&r),e.dispatchEvent(n)}},[c,r,a]);let m=n.useRef(!N(r)&&r);return(0,f.jsx)("input",{type:"checkbox","aria-hidden":!0,defaultChecked:null!=s?s:m.current,...i,tabIndex:-1,ref:l,style:{...e.style,...u,position:"absolute",pointerEvents:"none",opacity:0,margin:0}})};function N(e){return"indeterminate"===e}function w(e){return N(e)?"indeterminate":e?"checked":"unchecked"}var k=v,C=y},48897:function(e,t,r){"use strict";r.d(t,{f:function(){return d}});var n=r(64149),a=r(79442),s=r(20881),i="horizontal",l=["horizontal","vertical"],o=n.forwardRef((e,t)=>{let{decorative:r,orientation:n=i,...o}=e,d=l.includes(n)?n:i;return(0,s.jsx)(a.WV.div,{"data-orientation":d,...r?{role:"none"}:{"aria-orientation":"vertical"===d?d:void 0,role:"separator"},...o,ref:t})});o.displayName="Separator";var d=o},32437:function(e,t,r){"use strict";r.d(t,{D:function(){return a}});var n=r(64149);function a(e){let t=n.useRef({value:e,previous:e});return n.useMemo(()=>(t.current.value!==e&&(t.current.previous=t.current.value,t.current.value=e),t.current.previous),[e])}},73452:function(e,t,r){"use strict";r.d(t,{t:function(){return s}});var n=r(64149),a=r(61013);function s(e){let[t,r]=n.useState(void 0);return(0,a.b)(()=>{if(e){r({width:e.offsetWidth,height:e.offsetHeight});let t=new ResizeObserver(t=>{let n,a;if(!Array.isArray(t)||!t.length)return;let s=t[0];if("borderBoxSize"in s){let e=s.borderBoxSize,t=Array.isArray(e)?e[0]:e;n=t.inlineSize,a=t.blockSize}else n=e.offsetWidth,a=e.offsetHeight;r({width:n,height:a})});return t.observe(e,{box:"border-box"}),()=>t.unobserve(e)}r(void 0)},[e]),t}}},function(e){e.O(0,[792,4059,8714,217,4491,2310,8985,5330,1744],function(){return e(e.s=98910)}),_N_E=e.O()}]);