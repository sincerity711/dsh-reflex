window.__ModuleLoader__.load({
  id: '@sincerity711/dsh-reflex',
  factory: (require) => {
    const React = require('react')
    const { Button, Input } = require('@deepseek-ai/dsh-client-ui-primitives')
    const { createElement: h, useEffect, useState, useSyncExternalStore } = React
    const exports = { inject: ['slots', 'locale'] }
    const dictionaries = {
      en: { scenarios:'Trigger scenarios', teams:'Teams meetings', details:'Run details', back:'← Back', description:'Capture captions when a meeting starts and send them to DSH for a summary when it ends.', configure:'Settings and run history →', summarySettings:'Summary settings', model:'Automatic task model', modelHelp:'The model selected here is saved for automatic runs. Changing the DSH default does not change it.', modelUnavailable:'The saved model is not currently advertised. Restore its provider or select another model.', modelsUnavailable:'Some model providers could not be loaded. Refresh to try again.', modelLoading:'Loading models…', archiveDirectory:'Meeting archive directory', archiveDirectoryHelp:'Absolute path for meeting notes, summaries and program-generated transcripts. Leave empty to turn off archiving.', invalidModel:'Select a valid task model.', invalidArchiveDirectory:'Use an absolute archive directory or leave it empty.', prompt:'Summary prompt', promptHelp:'Control how DSH processes meeting captions.', workspace:'Working directory', workspaceHelp:'Absolute local path for the DSH summary session.', lookback:'Same-name meeting lookback (minutes)', lookbackHelp:'The model considers recent meetings with the same name and decides whether to combine them. Set to 0 to turn this off.', save:'Save settings', saved:'Settings saved', history:'Run history', refresh:'Refresh', noRuns:'No meeting runs yet.', transcript:'Captions', gaps:'Capture gaps', sentPrompt:'Sent prompt', summary:'Summary', raw:'Raw log', noCaptions:'No captions were available, so no summary was generated.', collecting:'Capturing captions; there is nothing to show yet.', noContent:'Nothing to show.', speaker:'Speaker', queued:'Queued', running:'In progress', succeeded:'Completed', failed:'Failed', cancelled:'Cancelled', timed_out:'Timed out', requestTooLarge:'The request is too large.', notLeader:'This instance is not the active Reflex instance.', jsonRequired:'A JSON request is required.', invalidRequest:'The request is invalid.', runNotFound:'The run was not found.', endpointNotFound:'The endpoint was not found.', settingsConflict:'Settings changed in another page. Refresh and try again.', invalidPrompt:'Enter a summary prompt of at most 50,000 characters.', absoluteWorkspace:'The working directory must be an absolute path.', missingWorkspace:'The working directory does not exist or is not a folder.', invalidLookback:'Lookback must be between 0 and 60 minutes.', unauthorized:'Access denied. Reopen DSH and try again.', unknownError:'The request failed. Please try again.', networkError:'Cannot connect to Reflex. Check that the plugin is running and try again.' },
      zh: { scenarios:'触发场景', teams:'Teams 会议', details:'执行详情', back:'← 返回', description:'会议开始时记录字幕，结束后自动交给 DSH 总结。', configure:'配置与执行记录 →', summarySettings:'总结设置', model:'自动任务模型', modelHelp:'保存后，自动任务使用此处选定的模型；修改 DSH 默认模型不会影响它。', modelUnavailable:'已保存的模型当前不在可用列表中，请恢复对应服务或选择其他模型。', modelsUnavailable:'部分模型服务加载失败，请刷新重试。', modelLoading:'正在加载模型…', archiveDirectory:'会议归档目录', archiveDirectoryHelp:'保存会议入口、纪要及程序生成的 transcript，使用绝对路径；留空关闭归档。', invalidModel:'请选择有效的任务模型。', invalidArchiveDirectory:'归档目录必须是绝对路径或留空。', prompt:'总结提示词', promptHelp:'控制 DSH 如何处理会议字幕。', workspace:'工作目录', workspaceHelp:'DSH 总结会话使用的本机绝对路径。', lookback:'同名会议回看时间（分钟）', lookbackHelp:'模型会参考近期同名会议，判断是否需要合并；设为 0 则关闭。', save:'保存设置', saved:'设置已保存', history:'执行记录', refresh:'刷新', noRuns:'暂无会议执行记录。', transcript:'源字幕', gaps:'采集缺口', sentPrompt:'发送的提示词', summary:'纪要', raw:'原始日志', noCaptions:'没有可用字幕，未生成纪要。', collecting:'正在采集，暂时没有可显示的内容。', noContent:'没有可显示的内容。', speaker:'发言人', queued:'等待中', running:'进行中', succeeded:'已完成', failed:'失败', cancelled:'已取消', timed_out:'超时', requestTooLarge:'请求过大。', notLeader:'当前实例不是 Reflex 主实例。', jsonRequired:'需要 JSON 请求。', invalidRequest:'请求格式无效。', runNotFound:'记录不存在。', endpointNotFound:'接口不存在。', settingsConflict:'设置已在其他页面更改，请刷新后重试。', invalidPrompt:'请输入不超过 50000 字符的总结提示词。', absoluteWorkspace:'工作目录必须是绝对路径。', missingWorkspace:'工作目录不存在或不是文件夹。', invalidLookback:'回看时间必须是 0–60 分钟。', unauthorized:'无访问权限，请重新打开 DSH 后重试。', unknownError:'请求失败，请重试。', networkError:'无法连接 Reflex，请确认插件正在运行后重试。' },
    }
    Object.assign(dictionaries.en, {
      setupTitle:'Set up Reflex', setupOpen:'Installation and permissions',
      setupIntro:'Install the local helper to capture Teams captions. macOS will ask you to confirm signing and Accessibility access. Listening stays off until you enable Teams.',
      setupInstall:'Install helper', setupRetry:'Retry installation', setupLater:'Later', setupClose:'Done',
      setupIdle:'Ready to install the helper on this Mac.', setupChecking:'Checking your Mac…', setupSigning:'Creating a local signing identity. Confirm the macOS prompt to continue.',
      setupBuilding:'Building and installing the helper and built-in programs…', setupTools:'Complete the Command Line Tools installation, then retry. Swift 6 or later is required; if tools are already installed, update Xcode.',
      setupAccess:'Open Accessibility settings', setupPermission:'Turn on DSH Reflex Helper in Accessibility. This window will update when permission is active.',
      setupReady:'Helper ready. Configure the Teams scenario below, then enable Teams from /reflex program enable teams and confirm the requested access.',
      setupLogs:'Installation details', helperConnecting:'Helper is connecting. Wait a moment, then retry.'
    })
    Object.assign(dictionaries.zh, {
      setupTitle:'设置 Reflex', setupOpen:'安装与权限',
      setupIntro:'安装本机助手，用于采集 Teams 字幕。macOS 会要求确认签名和辅助功能权限；Teams 监听需要之后主动启用。',
      setupInstall:'安装本机助手', setupRetry:'重试安装', setupLater:'稍后设置', setupClose:'完成',
      setupIdle:'准备安装本机助手。', setupChecking:'正在检查运行环境…', setupSigning:'正在创建本机签名，请确认 macOS 弹出的提示。',
      setupBuilding:'正在编译并安装助手和内置程序…', setupTools:'请完成系统弹出的开发工具安装，再点击重试。需要 Swift 6 或更高版本；若工具已安装，请更新 Xcode。',
      setupAccess:'打开辅助功能设置', setupPermission:'请在辅助功能中打开 DSH Reflex Helper。授权生效后，这里会自动更新。',
      setupReady:'助手已就绪。请在下方配置 Teams 场景，然后通过 /reflex program enable teams 按提示确认启用。',
      setupLogs:'安装详情', helperConnecting:'助手正在连接，请稍候重试。'
    })
    let openSetup = () => {}
    function installOnboarding() {
      if (typeof document === 'undefined') return () => {}
      let stopped = false, timer, dialog, current, shown = false, inFlight = false
      const text = key => (dictionaries[locale.getSnapshot().active.startsWith('zh') ? 'zh' : 'en'][key] || dictionaries.en[key] || key)
      const post = action => api('/setup/' + action, {method:'POST',headers:{'content-type':'application/json'},body:'{}'})
      const style = document.createElement('style')
      style.textContent = '.reflex-setup { box-sizing:border-box; width:min(520px,calc(100vw - 32px)); max-height:calc(100dvh - 48px); overflow:auto; padding:24px; border:1px solid var(--dsw-alias-border-l2); border-radius:14px; background:var(--dsw-alias-bg-base,Canvas); color:var(--dsw-alias-label-primary,CanvasText); font:13px/1.6 system-ui; } .reflex-setup::backdrop { background:rgb(0 0 0 / .4); } .reflex-setup h2 { margin:0 0 12px; font-size:18px; } .reflex-setup button { font:inherit; padding:8px 14px; border-radius:8px; border:1px solid var(--dsw-alias-border-l2); color:inherit; background:transparent; cursor:pointer; } .reflex-setup button:focus-visible { outline:2px solid currentColor; outline-offset:3px; } .reflex-setup button:disabled { opacity:.6; cursor:wait; } .reflex-setup pre { white-space:pre-wrap; overflow-wrap:anywhere; max-height:180px; overflow:auto; font-size:12px; }'
      document.head.append(style)
      const dismiss = async () => { if (dialog) dialog.close(); await post('dismiss').catch(() => {}) }
      const show = () => {
        if (!dialog) {
          dialog = document.createElement('dialog'); dialog.className = 'reflex-setup'; dialog.setAttribute('aria-labelledby','reflex-setup-title')
          const title = document.createElement('h2'); title.id = 'reflex-setup-title'; title.textContent = text('setupTitle')
          const intro = document.createElement('p'); intro.textContent = text('setupIntro')
          const message = document.createElement('p'); message.dataset.part = 'message'; message.setAttribute('role','status'); message.setAttribute('aria-live','polite')
          const error = document.createElement('p'); error.dataset.part = 'error'; error.setAttribute('role','alert')
          const details = document.createElement('details'), summary = document.createElement('summary'), logs = document.createElement('pre'); summary.textContent = text('setupLogs'); logs.dataset.part = 'logs'; details.append(summary,logs)
          const actions = document.createElement('div'); Object.assign(actions.style,{display:'flex',justifyContent:'flex-end',flexWrap:'wrap',gap:'8px',marginTop:'20px'})
          const later = document.createElement('button'); later.dataset.part = 'later'; later.addEventListener('click',() => { void dismiss() })
          const primary = document.createElement('button'); primary.dataset.part = 'primary'
          primary.addEventListener('click',async () => {
            if (inFlight) return
            inFlight = true; primary.disabled = true; error.textContent = ''
            try {
              if (current?.helper?.axTrusted && current?.phase !== 'failed') { await dismiss(); return }
              const action = current?.installed && !['failed','tools'].includes(current?.phase) ? 'access' : 'install'
              const result = await post(action)
              if (action === 'install') current = {...current,...result}
              await refresh()
            } catch (e) { error.textContent = text(e.message) }
            finally { inFlight = false; if (dialog?.open) render() }
          })
          actions.append(later,primary); dialog.append(title,intro,message,error,details,actions); document.body.append(dialog)
          dialog.addEventListener('cancel',e => { e.preventDefault(); void dismiss() })
        }
        shown = true; render(); if (!dialog.open) dialog.showModal()
      }
      const render = () => {
        if (!dialog || !current) return
        const busy = ['checking','signing','building'].includes(current.phase)
        const ready = current.helper?.axTrusted && current.phase !== 'failed'
        const key = ready ? 'setupReady' : ({checking:'setupChecking',signing:'setupSigning',building:'setupBuilding',tools:'setupTools'})[current.phase] || (current.installed ? 'setupPermission' : 'setupIdle')
        dialog.querySelector('[data-part="message"]').textContent = text(key)
        dialog.querySelector('[data-part="logs"]').textContent = current.log || ''
        dialog.querySelector('[data-part="error"]').textContent = current.error || ''
        const primary = dialog.querySelector('[data-part="primary"]')
        primary.disabled = busy || inFlight
        primary.textContent = text(ready ? 'setupClose' : busy ? ({checking:'setupChecking',signing:'setupChecking',building:'setupBuilding'})[current.phase] : current.phase === 'failed' || current.phase === 'tools' ? 'setupRetry' : current.installed ? 'setupAccess' : 'setupInstall')
        dialog.querySelector('[data-part="later"]').textContent = text('setupLater')
      }
      const refresh = async () => {
        try {
          const next = await api('/setup')
          if (stopped) return
          current = next
          if (!shown && !current.dismissed && current.platform === 'darwin' && (!current.installed || current.helper?.axTrusted === false)) show()
          render()
        } catch (_) {}
      }
      const tick = async () => { await refresh(); if (!stopped) timer = setTimeout(tick, dialog?.open ? 2000 : 10000) }
      openSetup = () => { show(); void refresh() }
      void tick()
      return () => { stopped = true; clearTimeout(timer); dialog?.remove(); style.remove(); openSetup = () => {} }
    }
    let locale
    const subscribeLocale = fn => locale.subscribe(fn)
    const localeSnapshot = () => locale.getSnapshot()
    const api = async (path, options) => {
      let res
      try { res = await fetch('/dsh-reflex/api' + path, options) } catch (_) { throw new Error('networkError') }
      let data
      try { data = await res.json() } catch (_) { throw new Error('unknownError') }
      if (!res.ok) throw new Error(Object.hasOwn(dictionaries.en, data.code) ? data.code : 'unknownError')
      return data
    }
    const muted = { color:'var(--dsw-alias-label-secondary)', fontSize:12, lineHeight:'18px' }
    const rowButton = { width:'100%', display:'flex', justifyContent:'space-between', gap:16, alignItems:'center', textAlign:'start', background:'transparent', color:'inherit', border:0, borderBottom:'0.5px solid var(--dsw-alias-border-l2)', padding:'12px 2px', cursor:'pointer', font:'inherit' }
    const input = { display:'block', boxSizing:'border-box', width:'100%', border:'1px solid var(--dsw-alias-border-l2)', borderRadius:8, padding:10, marginTop:8, background:'var(--dsw-alias-bg-base)', color:'inherit', font:'inherit', fontWeight:400, lineHeight:1.5 }
    const panel = { margin:'20px 0 28px' }
    const sectionTitle = { margin:0, fontSize:14, lineHeight:'20px', fontWeight:500 }
    function App({ t }) {
      const language = useSyncExternalStore(subscribeLocale, localeSnapshot, localeSnapshot).active
      const formatDate = value => { try { return new Date(value).toLocaleString(language === 'zh' ? 'zh-CN' : language) } catch (_) { return new Date(value).toLocaleString('en') } }
      const status = value => ['queued','running','succeeded','failed','cancelled','timed_out'].includes(value) ? t(value) : value
      const [page, setPage] = useState('scenarios'), [settings, setSettings] = useState(null), [revision, setRevision] = useState(''), [runs, setRuns] = useState([]), [detail, setDetail] = useState(null), [tab, setTab] = useState('transcript'), [error, setError] = useState(''), [notice, setNotice] = useState(''), [models, setModels] = useState([]), [modelWarning, setModelWarning] = useState(false), [saving, setSaving] = useState(false)
      const refresh = async () => { try { const [s, r, catalog] = await Promise.all([api('/settings'), api('/runs'), api('/models').catch(() => null)]); setModels(catalog?.models || []); setModelWarning(!catalog || catalog.unavailableProviders?.length > 0); setSettings({...s.settings, model:s.settings.model || catalog?.current || null}); setRevision(s.revision); setRuns(r.runs); setError('') } catch (e) { setError(e.message) } }
      useEffect(() => { void refresh() }, [])
      useEffect(() => { if (page !== 'detail' || !detail || !['running','queued'].includes(detail.run.status)) return; const id = setInterval(() => api('/runs/' + detail.run.runId).then(setDetail).catch(e => setError(e.message)), 3000); return () => clearInterval(id) }, [page, detail && detail.run.runId, detail && detail.run.status])
      async function save() { setSaving(true); try { const data = await api('/settings', { method:'PUT', headers: { 'content-type':'application/json' }, body: JSON.stringify({ settings, revision }) }); setSettings(data.settings); setRevision(data.revision); setNotice('saved'); setError('') } catch (e) { setError(e.message); setNotice('') } finally { setSaving(false) } }
      async function open(id) { try { setDetail(await api('/runs/' + id)); setPage('detail'); setTab('transcript'); setError(''); setNotice('') } catch (e) { setError(e.message) } }
      const title = t(page === 'scenarios' ? 'scenarios' : page === 'teams' ? 'teams' : 'details')
      const field = (name, label, help, type) => h('label', { style:{ display:'block', margin:'20px 0', fontSize:13, fontWeight:500 } }, label, h('span', { style:{ ...muted, display:'block', fontWeight:400, marginTop:4 } }, help), type === 'textarea' ? h('textarea', { style:{ ...input, minHeight:160, resize:'vertical' }, value:settings[name], onChange:e => setSettings({...settings,[name]:e.target.value}) }) : h(Input, { className:type === 'number' ? 'reflex-number' : 'reflex-input', type:type || 'text', min:type === 'number' ? 0 : undefined, max:type === 'number' ? 60 : undefined, value:settings[name], onChange:e => setSettings({...settings,[name]:type === 'number' ? Number(e.target.value) : e.target.value}) }))
      const modelKey = model => model ? JSON.stringify([model.provider, model.model]) : ''
      const choices = [...models]
      if (settings?.model && !choices.some(m => modelKey(m) === modelKey(settings.model))) choices.unshift({...settings.model, name:settings.model.model})
      const modelField = settings && h('label', {style:{display:'block',margin:'20px 0',fontSize:13,fontWeight:500}}, t('model'),
        h('span', {style:{...muted,display:'block',fontWeight:400,marginTop:4}}, t('modelHelp')),
        h('select', {style:input,value:modelKey(settings.model),onChange:e=>{ const [provider, model] = JSON.parse(e.target.value); setSettings({...settings,model:{provider,model}}) }},
          !settings.model && h('option',{value:'',disabled:true},t('modelLoading')),
          ...choices.map(m=>h('option',{key:modelKey(m),value:modelKey(m)},`${m.name} · ${m.provider}`))),
        settings.model && !models.some(m=>modelKey(m)===modelKey(settings.model)) && h('span',{style:{...muted,display:'block',marginTop:4},role:'status'},t('modelUnavailable')),
        modelWarning && h('span',{style:{...muted,display:'block',marginTop:4},role:'status'},t('modelsUnavailable')))
      const record = detail && detail.run, contents = detail && detail.contents
      const live = contents && contents.live
      let liveText = live || ''
      try { const data = JSON.parse(live); const lines = data.capture?.assembler?.lines || []; liveText = lines.map(line => `${line.speaker || t('speaker')}：${line.text || ''}`).join('\n') } catch (_) {}
      const content = contents && ({ transcript:contents.transcript || liveText, gaps:contents.gaps, prompt:contents.prompt, summary:contents.summary, raw:contents.raw })[tab]
      return h('section', { style:{ margin:'0 0 32px', maxWidth:760, fontSize:13, lineHeight:1.5 } },
        h('style', null, '.reflex-input { display:flex; width:100%; box-sizing:border-box; margin-top:8px; } .reflex-number { margin-top:8px; width:96px; box-sizing:border-box; }'),
        h('div', { style:{display:'flex', alignItems:'center', gap:12} }, page !== 'scenarios' && h(Button,{variant:'ghost',size:'sm',onClick:()=>{ setPage(page === 'detail' ? 'teams' : 'scenarios'); setError(''); void refresh() }},t('back')), h('h2',{style:sectionTitle},title)),
        error && h('p',{role:'alert',style:{color:'var(--dsw-alias-state-error-primary, #b42318)',whiteSpace:'pre-wrap'}},t(error)), notice && h('p',{role:'status'},t(notice)),
        h(Button,{variant:'outline',size:'sm',onClick:()=>openSetup()},t('setupOpen')),
        page === 'scenarios' && h('div',{style:panel},h('div',{style:{borderBottom:'0.5px solid var(--dsw-alias-border-l2)',padding:'0 2px 14px'}},h('strong',{style:{fontSize:13,fontWeight:500}},t('teams')),h('p',{style:{...muted,margin:'4px 0 12px'}},t('description')),h(Button,{variant:'outline',size:'sm',onClick:()=>{setPage('teams');setNotice('')}},t('configure')))),
        page === 'teams' && settings && h(React.Fragment,null,
          h('div',{style:panel},h('h3',{style:sectionTitle},t('summarySettings')),modelField,field('prompt',t('prompt'),t('promptHelp'),'textarea'),field('workspace',t('workspace'),t('workspaceHelp')),field('lookbackMinutes',t('lookback'),t('lookbackHelp'),'number'),field('archiveDirectory',t('archiveDirectory'),t('archiveDirectoryHelp')),h(Button,{variant:'primary',size:'sm',disabled:saving || !settings.model,onClick:save},t('save'))),
          h('div',{style:panel},h('div',{style:{display:'flex',justifyContent:'space-between',alignItems:'center'}},h('h3',{style:sectionTitle},t('history')),h(Button,{variant:'ghost',size:'sm',onClick:refresh},t('refresh'))),runs.length === 0 ? h('p',{style:{opacity:.7}},t('noRuns')) : runs.map(r=>h('button',{key:r.runId,style:rowButton,onClick:()=>open(r.runId)},h('span',null,String(r.title || t('teams')),' · ',formatDate(r.createdAt)),h('span',{style:muted},status(r.status)))))) ,
        page === 'detail' && record && h('div',{style:panel},h('strong',{style:{fontWeight:500}},String(record.event.payload?.title || t('teams'))),h('p',null,status(record.status),' · ',formatDate(record.createdAt), record.currentStep ? ' · '+record.currentStep : ''),record.error && h('p',{role:'alert'},record.error),...Object.values(record.steps || {}).filter(s=>s.error || s.status === 'no_captions').map(s=>h('p',{key:s.id,role:'status'},s.error || t('noCaptions'))),
          h('div',{style:{display:'flex',flexWrap:'wrap',gap:6}},...[['transcript','transcript'],['gaps','gaps'],['prompt','sentPrompt'],['summary','summary'],['raw','raw']].map(([key,label])=>h(Button,{key,variant:tab===key?'outline':'ghost',size:'sm','aria-pressed':tab===key,onClick:()=>setTab(key)},t(label)))),h('pre',{style:{whiteSpace:'pre-wrap',overflowWrap:'anywhere',font:'inherit',fontSize:13,maxHeight:500,overflow:'auto',opacity:content?1:.65}},content || (record.status === 'running' ? t('collecting') : t('noContent'))))
      )
    }
    exports.apply = ctx => {
      locale = ctx.locale
      ctx.effect(installOnboarding, 'dsh-reflex: first-run setup')
      ctx.effect(() => {
        let desired, sent, busy = false, stopped = false, timer
        const sync = async () => {
          if (stopped || busy || desired === sent) return
          busy = true
          const language = desired
          try {
            await api('/locale', { method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({locale:language}) })
            sent = language
          } catch (_) {
            if (!stopped) timer = setTimeout(() => { timer = undefined; void sync() }, 2000)
          } finally {
            busy = false
            if (!stopped && timer === undefined && desired !== sent) void sync()
          }
        }
        const update = () => { desired = ctx.locale.getSnapshot().active; if (timer !== undefined) { clearTimeout(timer); timer = undefined }; void sync() }
        update()
        const unsubscribe = ctx.locale.subscribe(update)
        return () => { stopped = true; if (timer !== undefined) clearTimeout(timer); unsubscribe() }
      }, 'dsh-reflex: menu locale')
      ctx.effect(() => ctx.locale.register('dsh-reflex', dictionaries), 'dsh-reflex: translations')
      ctx.slots.inject('plugins.bundle.config', () => ctx.slots.register({ name:'plugins.bundle.config', key:'@sincerity711/dsh-reflex', locale:'dsh-reflex' }, App))
    }
    return exports
  },
})
