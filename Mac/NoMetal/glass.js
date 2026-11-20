(function(){
 const roots=new Set(); let queued=false;
 function scan(root){if(!root||roots.has(root))return;roots.add(root);new MutationObserver(schedule).observe(root,{childList:true,subtree:true,attributes:true,attributeFilter:['style']}); inspect(root)}
 function set(e,k,v){if(e.style.getPropertyValue(k)!==v)e.style.setProperty(k,v)}
 function inspect(root){for(const e of root.querySelectorAll('*')){if(e.shadowRoot)scan(e.shadowRoot);if(e.localName==='flt-backdrop-filter'){const r=e.getBoundingClientRect(),side=Math.max(innerWidth,innerHeight);const x=(innerWidth-side)/2-r.left,y=(innerHeight-side)/2-r.top;set(e,'background-image','url("/assets/assets/background-blurred.png")');set(e,'background-repeat','no-repeat');set(e,'background-size',`${side}px ${side}px`);set(e,'background-position',`${x}px ${y}px`)}}}
 function schedule(){if(queued)return;queued=true;requestAnimationFrame(()=>{queued=false;for(const r of roots)inspect(r)})}
 window.addEventListener('resize',schedule);window.addEventListener('scroll',schedule,true);scan(document);schedule();
})();
