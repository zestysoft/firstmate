import os, subprocess, tempfile, pathlib, time, shutil, html
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/ian.brown/.no-mistakes/evidence/01M5FZWDRH0GVV50DFXZZ5X38S')
for cli in ['codex','claude']:
    lab=pathlib.Path(tempfile.mkdtemp(prefix='.phase-lab-',dir=root))
    env=os.environ.copy()
    for k in list(env):
        if k.endswith('_OVERRIDE') or k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','CLAUDECODE']:
            env.pop(k,None)
    sock=None
    log=[]
    try:
        subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
        sock=subprocess.check_output(['bin/fm-lab-home.sh','tmux-dir',str(lab)],text=True).strip()
        env['TMUX_TMPDIR']=sock
        env['FM_HOME']=str(lab)
        (lab/'config/supervision-host-off').touch()
        command=['tmux','-L','fm-lab','new-session','-d','-x','120','-y','40','-s','primary','-c',str(root),'-e','FM_HOME='+str(lab),cli]
        p=subprocess.run(command,env=env,text=True,capture_output=True)
        log.append('launch rc='+str(p.returncode)+'\n'+p.stdout+p.stderr)
        if p.returncode==0:
            time.sleep(12)
            p=subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],env=env,text=True,capture_output=True)
            log.append('viewport rc='+str(p.returncode)+'\n'+p.stdout+p.stderr)
            (evidence/(cli+'-interactive.html')).write_text('<!doctype html><meta charset="utf-8"><title>'+cli+' lab terminal</title><pre style="background:#141414;color:#eee;padding:24px;font:15px monospace">'+html.escape(p.stdout)+'</pre>')
    finally:
        if sock:
            p=subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,text=True,capture_output=True)
            log.append('private server cleanup rc='+str(p.returncode)+' '+p.stderr)
            p=subprocess.run(['bin/fm-lab-home.sh','teardown',str(lab)],text=True,capture_output=True)
            log.append('socket cleanup rc='+str(p.returncode)+' '+p.stderr)
        shutil.rmtree(lab)
        (evidence/(cli+'-interactive.log')).write_text('\n'.join(log))
        print(cli+'\n'+'\n'.join(log))
