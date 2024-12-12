(self.webpackChunk_N_E=self.webpackChunk_N_E||[]).push([[9878],{26888:function(e,n,t){Promise.resolve().then(t.bind(t,13967))},13967:function(e,n,t){"use strict";t.r(n),t.d(n,{default:function(){return o}});var r=t(20881),s=t(64149),a=t(94920),l=()=>{let[e,n]=(0,s.useState)(null),[t,r]=(0,s.useState)(!0),a=(0,s.useCallback)(async()=>{try{r(!0);let e=await fetch("/cgi-bin/fetch_data.sh?set=3"),t=await e.json();console.log("Fetched about data:",t);let s={manufacturer:t[0].response.split("\n")[1].trim(),model:t[1].response.split("\n")[1].trim(),firmwareVersion:t[2].response.split("\n")[1].trim(),phoneNum:t[3].response.split("\n")[1].split(":")[1].split(",")[1].replace(/"/g,"").trim(),imsi:t[4].response.split("\n")[1].trim(),iccid:t[5].response.split("\n")[1].split(":")[1].trim(),imei:t[6].response.split("\n")[1].trim(),currentDeviceIP:t[7].response.split("\n")[1].split(",")[1].replace(/"/g,"").trim(),lanGateway:t[7].response.split("\n")[1].split(":")[1].split(",")[3].replace(/"/g,"").trim(),wwanIPv4:t[8].response.split("\n")[1].split(":")[1].split(",")[4].replace(/"/g,"").trim(),wwanIPv6:t[8].response.split("\n")[2].split(",")[4].replace(/"/g,"").trim(),lteCategory:t[9].response.split("\n")[5].split(":")[2].trim()};n(s),console.log("Processed cell settings data:",s)}catch(e){console.error("Error fetching cell settings data:",e)}r(!1)},[]);return(0,s.useEffect)(()=>{a()},[a]),{data:e,isLoading:t,fetchAboutData:a}},i=t(24004),c=t(88766),o=()=>{let{data:e,isLoading:n}=l();return(0,r.jsxs)(a.Zb,{children:[(0,r.jsxs)(a.Ol,{children:[(0,r.jsx)(a.ll,{children:"QuecManager"}),(0,r.jsx)(a.SZ,{children:"What is QuecManager and how it can help you."})]}),(0,r.jsxs)(a.aY,{className:"grid lg:grid-cols-2 grid-cols-1 grid-flow-row gap-8",children:[(0,r.jsxs)(a.Zb,{children:[(0,r.jsxs)(a.Ol,{children:[(0,r.jsx)(a.ll,{children:"Device Technical Details"}),(0,r.jsx)(a.SZ,{children:"View technical details of your device."})]}),(0,r.jsx)(a.aY,{children:(0,r.jsxs)(i.x,{className:"w-full",children:[(0,r.jsxs)("div",{className:"grid gap-2",children:[(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"Modem Manufacturer"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.manufacturer)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"Modem Model"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.model)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"Firmware Revision"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.firmwareVersion)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"LTE Category"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsxs)(r.Fragment,{children:["CAT-",(null==e?void 0:e.lteCategory)||"N/A"]})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"Active Phone Number"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.phoneNum)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"Active IMSI"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.imsi)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"Active ICCID"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.iccid)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"IMEI"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.imei)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"Current Device IP"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.currentDeviceIP)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"LAN Gateway"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.lanGateway)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"WWAN IPv4"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.wwanIPv4)||"N/A"})})]}),(0,r.jsxs)("div",{className:"flex items-center justify-between",children:[(0,r.jsx)("span",{children:"WWAN IPv6"}),(0,r.jsx)("span",{className:"font-semibold max-w-32 md:max-w-full truncate",children:n?(0,r.jsx)(c.O,{className:"h-4 w-32"}):(0,r.jsx)(r.Fragment,{children:(null==e?void 0:e.wwanIPv6)||"N/A"})})]})]}),(0,r.jsx)(i.B,{orientation:"horizontal"})]})})]}),(0,r.jsxs)(a.Zb,{children:[(0,r.jsxs)(a.Ol,{children:[(0,r.jsx)(a.ll,{children:"About Us"}),(0,r.jsx)(a.SZ,{children:"Who we are and what we do."})]}),(0,r.jsxs)(a.aY,{className:"space-y-6",children:[(0,r.jsxs)("div",{className:"grid gap-2",children:[(0,r.jsx)("h1",{className:"text-xl font-bold antialiased",children:"QuecManager"}),(0,r.jsx)("p",{className:"text-md font-medium antialiased",children:"QuecManager began as 'Simple Admin,' a straightforward GUI in the RGMII toolkit. Over time, it’s evolved into a comprehensive dashboard with powerful features for managing cellular modems. While we’ve moved beyond the 'Simple' name, our goal remains the same: providing a clean, easy-to-use interface that makes advanced modem management feel straightforward and accessible."})]}),(0,r.jsxs)("div",{children:[(0,r.jsx)("h1",{className:"text-xl font-bold antialiased",children:"Thanks to"}),(0,r.jsxs)("ul",{className:"list-disc list-inside text-md font-medium antialiased",children:[(0,r.jsxs)("li",{children:["RGMII Toolkit and Documentation, and Backend",(0,r.jsx)("a",{href:"https://github.com/iamromulan",target:"_blank",className:"text-primary font-semibold ml-2",children:"iamromulan"})]}),(0,r.jsxs)("li",{children:["Simple Admin 2.0 and QuecManager GUI",(0,r.jsx)("a",{href:"https://github.com/dr-dolomite",target:"_blank",className:"text-primary font-semibold ml-2",children:"dr-dolomite"})]}),(0,r.jsxs)("li",{children:["SMS Feature",(0,r.jsx)("a",{href:"https://github.com/snjzb",target:"_blank",className:"text-primary font-semibold ml-2",children:"snjzb"})]}),(0,r.jsxs)("li",{children:["Original Simple Admin",(0,r.jsx)("a",{href:"https://github.com/aesthernr",target:"_blank",className:"text-primary font-semibold ml-2",children:"aesthernr"})]}),(0,r.jsxs)("li",{children:["Original Socat Bridge",(0,r.jsx)("a",{href:"https://github.com/natecarlson",target:"_blank",className:"text-primary font-semibold ml-2",children:"natecarlson"})]}),(0,r.jsx)("li",{children:"Wutang Clan"})]})]})]})]})]}),(0,r.jsx)(a.eW,{className:"flex justify-center",children:(0,r.jsx)("p",{children:"QuecManager \xa9 2024 - For Personal Use Only. All rights reserved."})})]})}},94920:function(e,n,t){"use strict";t.d(n,{Ol:function(){return i},SZ:function(){return o},Zb:function(){return l},aY:function(){return d},eW:function(){return u},ll:function(){return c}});var r=t(20881),s=t(64149),a=t(90270);let l=s.forwardRef((e,n)=>{let{className:t,...s}=e;return(0,r.jsx)("div",{ref:n,className:(0,a.cn)("rounded-xl border bg-card text-card-foreground shadow",t),...s})});l.displayName="Card";let i=s.forwardRef((e,n)=>{let{className:t,...s}=e;return(0,r.jsx)("div",{ref:n,className:(0,a.cn)("flex flex-col space-y-1.5 p-6",t),...s})});i.displayName="CardHeader";let c=s.forwardRef((e,n)=>{let{className:t,...s}=e;return(0,r.jsx)("h3",{ref:n,className:(0,a.cn)("font-semibold leading-none tracking-tight",t),...s})});c.displayName="CardTitle";let o=s.forwardRef((e,n)=>{let{className:t,...s}=e;return(0,r.jsx)("p",{ref:n,className:(0,a.cn)("text-sm text-muted-foreground",t),...s})});o.displayName="CardDescription";let d=s.forwardRef((e,n)=>{let{className:t,...s}=e;return(0,r.jsx)("div",{ref:n,className:(0,a.cn)("p-6 pt-0",t),...s})});d.displayName="CardContent";let u=s.forwardRef((e,n)=>{let{className:t,...s}=e;return(0,r.jsx)("div",{ref:n,className:(0,a.cn)("flex items-center p-6 pt-0",t),...s})});u.displayName="CardFooter"},24004:function(e,n,t){"use strict";t.d(n,{B:function(){return c},x:function(){return i}});var r=t(20881),s=t(64149),a=t(82310),l=t(90270);let i=s.forwardRef((e,n)=>{let{className:t,children:s,...i}=e;return(0,r.jsxs)(a.fC,{ref:n,className:(0,l.cn)("relative overflow-hidden",t),...i,children:[(0,r.jsx)(a.l_,{className:"h-full w-full rounded-[inherit]",children:s}),(0,r.jsx)(c,{}),(0,r.jsx)(a.Ns,{})]})});i.displayName=a.fC.displayName;let c=s.forwardRef((e,n)=>{let{className:t,orientation:s="vertical",...i}=e;return(0,r.jsx)(a.gb,{ref:n,orientation:s,className:(0,l.cn)("flex touch-none select-none transition-colors","vertical"===s&&"h-full w-2.5 border-l border-l-transparent p-[1px]","horizontal"===s&&"h-2.5 flex-col border-t border-t-transparent p-[1px]",t),...i,children:(0,r.jsx)(a.q4,{className:"relative flex-1 rounded-full bg-border"})})});c.displayName=a.gb.displayName},88766:function(e,n,t){"use strict";t.d(n,{O:function(){return a}});var r=t(20881),s=t(90270);function a(e){let{className:n,...t}=e;return(0,r.jsx)("div",{className:(0,s.cn)("animate-pulse rounded-md bg-primary/10",n),...t})}},90270:function(e,n,t){"use strict";t.d(n,{cn:function(){return a}});var r=t(33958),s=t(61779);function a(){for(var e=arguments.length,n=Array(e),t=0;t<e;t++)n[t]=arguments[t];return(0,s.m6)((0,r.W)(n))}},64433:function(e,n,t){"use strict";function r(e,n,{checkForDefaultPrevented:t=!0}={}){return function(r){if(e?.(r),!1===t||!r.defaultPrevented)return n?.(r)}}t.d(n,{M:function(){return r}})},74873:function(e,n,t){"use strict";t.d(n,{b:function(){return l},k:function(){return a}});var r=t(64149),s=t(20881);function a(e,n){let t=r.createContext(n),a=e=>{let{children:n,...a}=e,l=r.useMemo(()=>a,Object.values(a));return(0,s.jsx)(t.Provider,{value:l,children:n})};return a.displayName=e+"Provider",[a,function(s){let a=r.useContext(t);if(a)return a;if(void 0!==n)return n;throw Error(`\`${s}\` must be used within \`${e}\``)}]}function l(e,n=[]){let t=[],a=()=>{let n=t.map(e=>r.createContext(e));return function(t){let s=t?.[e]||n;return r.useMemo(()=>({[`__scope${e}`]:{...t,[e]:s}}),[t,s])}};return a.scopeName=e,[function(n,a){let l=r.createContext(a),i=t.length;t=[...t,a];let c=n=>{let{scope:t,children:a,...c}=n,o=t?.[e]?.[i]||l,d=r.useMemo(()=>c,Object.values(c));return(0,s.jsx)(o.Provider,{value:d,children:a})};return c.displayName=n+"Provider",[c,function(t,s){let c=s?.[e]?.[i]||l,o=r.useContext(c);if(o)return o;if(void 0!==a)return a;throw Error(`\`${t}\` must be used within \`${n}\``)}]},function(...e){let n=e[0];if(1===e.length)return n;let t=()=>{let t=e.map(e=>({useScope:e(),scopeName:e.scopeName}));return function(e){let s=t.reduce((n,{useScope:t,scopeName:r})=>{let s=t(e)[`__scope${r}`];return{...n,...s}},{});return r.useMemo(()=>({[`__scope${n.scopeName}`]:s}),[s])}};return t.scopeName=n.scopeName,t}(a,...n)]}},45485:function(e,n,t){"use strict";t.d(n,{z:function(){return l}});var r=t(64149),s=t(83954),a=t(61013),l=e=>{var n,t;let l,c;let{present:o,children:d}=e,u=function(e){var n,t;let[s,l]=r.useState(),c=r.useRef({}),o=r.useRef(e),d=r.useRef("none"),[u,m]=(n=e?"mounted":"unmounted",t={mounted:{UNMOUNT:"unmounted",ANIMATION_OUT:"unmountSuspended"},unmountSuspended:{MOUNT:"mounted",ANIMATION_END:"unmounted"},unmounted:{MOUNT:"mounted"}},r.useReducer((e,n)=>{let r=t[e][n];return null!=r?r:e},n));return r.useEffect(()=>{let e=i(c.current);d.current="mounted"===u?e:"none"},[u]),(0,a.b)(()=>{let n=c.current,t=o.current;if(t!==e){let r=d.current,s=i(n);e?m("MOUNT"):"none"===s||(null==n?void 0:n.display)==="none"?m("UNMOUNT"):t&&r!==s?m("ANIMATION_OUT"):m("UNMOUNT"),o.current=e}},[e,m]),(0,a.b)(()=>{if(s){var e;let n;let t=null!==(e=s.ownerDocument.defaultView)&&void 0!==e?e:window,r=e=>{let r=i(c.current).includes(e.animationName);if(e.target===s&&r&&(m("ANIMATION_END"),!o.current)){let e=s.style.animationFillMode;s.style.animationFillMode="forwards",n=t.setTimeout(()=>{"forwards"===s.style.animationFillMode&&(s.style.animationFillMode=e)})}},a=e=>{e.target===s&&(d.current=i(c.current))};return s.addEventListener("animationstart",a),s.addEventListener("animationcancel",r),s.addEventListener("animationend",r),()=>{t.clearTimeout(n),s.removeEventListener("animationstart",a),s.removeEventListener("animationcancel",r),s.removeEventListener("animationend",r)}}m("ANIMATION_END")},[s,m]),{isPresent:["mounted","unmountSuspended"].includes(u),ref:r.useCallback(e=>{e&&(c.current=getComputedStyle(e)),l(e)},[])}}(o),m="function"==typeof d?d({present:u.isPresent}):r.Children.only(d),f=(0,s.e)(u.ref,(l=null===(n=Object.getOwnPropertyDescriptor(m.props,"ref"))||void 0===n?void 0:n.get)&&"isReactWarning"in l&&l.isReactWarning?m.ref:(l=null===(t=Object.getOwnPropertyDescriptor(m,"ref"))||void 0===t?void 0:t.get)&&"isReactWarning"in l&&l.isReactWarning?m.props.ref:m.props.ref||m.ref);return"function"==typeof d||u.isPresent?r.cloneElement(m,{ref:f}):null};function i(e){return(null==e?void 0:e.animationName)||"none"}l.displayName="Presence"},79442:function(e,n,t){"use strict";t.d(n,{WV:function(){return i},jH:function(){return c}});var r=t(64149),s=t(50149),a=t(54098),l=t(20881),i=["a","button","div","form","h2","h3","img","input","label","li","nav","ol","p","span","svg","ul"].reduce((e,n)=>{let t=r.forwardRef((e,t)=>{let{asChild:r,...s}=e,i=r?a.g7:n;return"undefined"!=typeof window&&(window[Symbol.for("radix-ui")]=!0),(0,l.jsx)(i,{...s,ref:t})});return t.displayName=`Primitive.${n}`,{...e,[n]:t}},{});function c(e,n){e&&s.flushSync(()=>e.dispatchEvent(n))}},2441:function(e,n,t){"use strict";t.d(n,{W:function(){return s}});var r=t(64149);function s(e){let n=r.useRef(e);return r.useEffect(()=>{n.current=e}),r.useMemo(()=>(...e)=>n.current?.(...e),[])}},61013:function(e,n,t){"use strict";t.d(n,{b:function(){return s}});var r=t(64149),s=globalThis?.document?r.useLayoutEffect:()=>{}}},function(e){e.O(0,[4059,2310,8985,5330,1744],function(){return e(e.s=26888)}),_N_E=e.O()}]);