(function(){
  // Sticky header shrink
  var hdr=document.getElementById('hdr');
  var onScroll=function(){ if(window.scrollY>16) hdr.classList.add('scrolled'); else hdr.classList.remove('scrolled'); };
  window.addEventListener('scroll',onScroll,{passive:true}); onScroll();

  // Mobile menu
  var burger=document.getElementById('burger'), nav=document.getElementById('nav');
  burger.addEventListener('click',function(){ nav.classList.toggle('open'); });
  nav.querySelectorAll('a').forEach(function(a){ a.addEventListener('click',function(){ nav.classList.remove('open'); }); });

  var reduce=window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Scroll reveal
  if('IntersectionObserver' in window && !reduce){
    var io=new IntersectionObserver(function(es){ es.forEach(function(e){ if(e.isIntersecting){ e.target.classList.add('in'); io.unobserve(e.target); } }); },{threshold:.14});
    document.querySelectorAll('.reveal').forEach(function(el){ io.observe(el); });
  } else { document.querySelectorAll('.reveal').forEach(function(el){ el.classList.add('in'); }); }

  // Count-up
  function countUp(el){ var target=parseInt(el.getAttribute('data-count'),10)||0; var suf=el.getAttribute('data-suffix')||''; var t0=null,dur=1400;
    function step(ts){ if(!t0)t0=ts; var p=Math.min((ts-t0)/dur,1); var val=Math.floor((0.5-Math.cos(Math.PI*p)/2)*target); el.textContent=val.toLocaleString('sl-SI')+suf; if(p<1)requestAnimationFrame(step); else el.textContent=target.toLocaleString('sl-SI')+suf; }
    requestAnimationFrame(step);
  }
  var counted=false;
  if('IntersectionObserver' in window && !reduce){
    var co=new IntersectionObserver(function(es){ es.forEach(function(e){ if(e.isIntersecting){ document.querySelectorAll('[data-count]').forEach(countUp); co.disconnect(); } }); },{threshold:.4});
    var s=document.querySelector('.hero-stats'); if(s)co.observe(s);
  } else { document.querySelectorAll('[data-count]').forEach(function(el){ el.textContent=el.getAttribute('data-count')+(el.getAttribute('data-suffix')||''); }); }

  // Ocene (prave Google ocene)
  var revs=[
    {n:"Ines Vrhovec",p:"https://lh3.googleusercontent.com/a-/ALV-UjUei0qRDt07Gm1XoY6fddZkZZTteJIMZRWOKUJhxYXTcldUlSnUGA=w96-h96-c-rp-mo-br100",t:"Zelo zadovoljna! 😊 RabimBox z veseljem priporočam in se zagotovo še vrnem!"},
    {n:"jaka žabjek",p:"https://lh3.googleusercontent.com/a-/ALV-UjVak3xiJZUSJKFRD58Iq7ieG0PHZ5RPWBjn_BnyoWIYLYfqYWM=w96-h96-c-rp-mo-br100",t:"Zelo zanesljivi, hitra in profesionalna storitev! Priporočam!"},
    {n:"Primož Petrovič Vernikov",p:"https://lh3.googleusercontent.com/a/ACg8ocJXdymK4-6zHySVZk9Gx_tdGcsBw_tpzGBeilUduvlaOwhkTw=w96-h96-c-rp-mo-br100",t:"Super storitev, prijazno osebje!"},
    {n:"Nataša Jalen",p:"https://lh3.googleusercontent.com/a-/ALV-UjWHkrvIMl91YLd-aMMZTspDT2mkPpMaoLKxiwdFm2Scwc-IcVNF=w96-h96-c-rp-mo-br100",t:"Po mnogih stresnih selitvah sem našla RabimBox. Izjemna odzivnost, profesionalna storitev, ugodna cena. Toplo priporočam!"},
    {n:"Anita Mulahmetović",p:"https://lh3.googleusercontent.com/a/ACg8ocJVJz5qqU3cLmEww6aICPtED-gIhMA3gOVJnXbgFws8qkhRZg=w96-h96-c-rp-mo-br100",t:"Vedno ko smo naročili je bilo vse pravočasno, korektno in ugodno narejeno! Priporočam vsem 💪"},
    {n:"novimales",p:"https://lh3.googleusercontent.com/a/ACg8ocJaGu9Q8uIqk2u-X-cNM5jdTv5z8mhm8bKbfABQMWLuH9NjVQ=w96-h96-c-rp-mo-br100",t:"Enostavno, hitro, ugodno - top👌"},
    {n:"Urban Pahor",p:"https://lh3.googleusercontent.com/a-/ALV-UjWZCozMGpYqZJzUokfqtIUwnlBYAGe1UqhMzIPp6bdquWR5Yv6o=w96-h96-c-rp-mo-ba12-br100",t:"Super zadeva. Bili so zelo odzivni in prijazni."}
  ];
  var cols=['#4285F4','#EA4335','#34A853','#e7711b','#8E44AD','#16A085','#2C82C9'];
  function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
  var G='<svg width="20" height="20" viewBox="0 0 48 48" style="flex:0 0 20px"><path fill="#4285F4" d="M45.12 24.5c0-1.56-.14-3.06-.4-4.5H24v8.51h11.84c-.51 2.75-2.06 5.08-4.39 6.64v5.52h7.11c4.16-3.83 6.56-9.47 6.56-16.17z"/><path fill="#34A853" d="M24 46c5.94 0 10.92-1.97 14.56-5.33l-7.11-5.52c-1.97 1.32-4.49 2.1-7.45 2.1-5.73 0-10.58-3.87-12.31-9.07H4.34v5.7C7.96 41.07 15.4 46 24 46z"/><path fill="#FBBC05" d="M11.69 28.18c-.44-1.32-.69-2.73-.69-4.18s.25-2.86.69-4.18v-5.7H4.34C2.85 17.09 2 20.45 2 24s.85 6.91 2.34 9.88l7.35-5.7z"/><path fill="#EA4335" d="M24 10.75c3.23 0 6.13 1.11 8.41 3.29l6.31-6.31C34.91 4.18 29.93 2 24 2 15.4 2 7.96 6.93 4.34 14.12l7.35 5.7c1.73-5.2 6.58-9.07 12.31-9.07z"/></svg>';
  var VB='<svg width="15" height="15" viewBox="0 0 24 24"><circle cx="12" cy="12" r="12" fill="#4A90E2"/><path d="M17.2 8.4l-6.6 6.6-3.4-3.4 1.4-1.4 2 2 5.2-5.2z" fill="#fff"/></svg>';
  var track=document.getElementById('rvTrack');
  if(track){
    track.innerHTML=revs.map(function(r,i){var init=(r.n.trim().charAt(0)||'?').toUpperCase();
      return '<div class="rv-card"><div class="rv-top"><div class="rv-av" style="background:'+cols[i%cols.length]+'">'+esc(init)+'<img src="'+r.p+'" referrerpolicy="no-referrer" onerror="this.style.display=\'none\'"></div><div class="rv-name">'+esc(r.n)+'</div>'+G+'</div><div class="rv-row2"><span class="rv-cstars">★★★★★</span>'+VB+'</div><div class="rv-text">'+esc(r.t)+'</div><button class="rv-more" type="button">Preberi več</button></div>';
    }).join("");
    var pv=document.querySelector('.rv-prev'),nx=document.querySelector('.rv-next');
    if(pv)pv.onclick=function(){track.scrollBy({left:-(track.clientWidth||318),behavior:'smooth'});};
    if(nx)nx.onclick=function(){track.scrollBy({left:(track.clientWidth||318),behavior:'smooth'});};
    track.querySelectorAll('.rv-more').forEach(function(b){var card=b.parentNode,txt=card.querySelector('.rv-text');requestAnimationFrame(function(){if(txt.scrollHeight-txt.clientHeight<4)b.style.display='none';});b.addEventListener('click',function(){var o=card.classList.toggle('open');b.textContent=o?'Skrij':'Preberi več';});});
  }
})();
