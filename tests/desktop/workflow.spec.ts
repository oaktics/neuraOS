import { test,expect } from '@playwright/test';
test('create, execute, inspect artifact, accept, recover after page reload',async({page})=>{
  const errors:string[]=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto('/');await page.getByRole('button',{name:'Today',exact:true}).click();await expect(page.getByText('稼働中',{exact:true})).toBeVisible();await expect(page.getByText('最初のひとつを、ここから。')).toBeVisible();
  await page.screenshot({path:'.tmp/evidence/today.png',fullPage:true,animations:'disabled'});
  await page.getByRole('button',{name:'達成したいことを入力'}).click();
  const dialog=page.getByRole('dialog');await dialog.getByLabel('達成したいこと').fill('提供した資料から週末の予定を整理してください。');await dialog.getByLabel('タイトル',{exact:true}).fill('週末の予定を整理');await dialog.getByRole('combobox',{name:'エージェント',exact:true}).click();await expect(page.getByRole('listbox')).toBeVisible();await page.screenshot({path:'.tmp/evidence/select-menu.png',fullPage:true,animations:'disabled'});await page.keyboard.press('End');await expect(page.getByRole('option',{name:/固定fixture/})).toBeFocused();await page.keyboard.press('Enter');await expect(dialog.getByRole('combobox',{name:'エージェント',exact:true})).toContainText('fixture');
  await dialog.getByRole('button',{name:'タスクを作成',exact:true}).click();await expect(dialog).not.toBeVisible();
  await page.getByRole('button',{name:'実行',exact:true}).click();await expect(page.getByText('result.md',{exact:true})).toBeVisible({timeout:10000});await expect(page.getByText('これは固定fixtureです。AIによる実行ではありません。',{exact:false})).toBeVisible();
  await page.screenshot({path:'.tmp/evidence/task-detail.png',fullPage:true,animations:'disabled'});
  await page.getByRole('button',{name:'確認して受け入れる'}).click();await expect(page.getByText('必須の完了条件を確認しました。')).toBeVisible({timeout:10000});
  await page.reload();await page.getByRole('navigation',{name:'タスク一覧',exact:true}).getByRole('button',{name:/週末の予定を整理/}).click();await expect(page.getByText('必須の完了条件を確認しました。')).toBeVisible();
  await page.getByRole('button',{name:'適用した記憶'}).click();await expect(page.getByText('適用された記憶はありません')).toBeVisible();
  await page.setViewportSize({width:760,height:900});await expect(page.locator('body')).toHaveJSProperty('scrollWidth',760);await page.screenshot({path:'.tmp/evidence/narrow.png',fullPage:true,animations:'disabled'});
  expect(errors).toEqual([]);
});
test('projects and explicit memories can be created and deleted',async({page})=>{
  await page.goto('/');await page.getByRole('button',{name:'Projects',exact:true}).click();await page.getByRole('button',{name:'プロジェクトを追加'}).click();const dialog=page.getByRole('dialog');await dialog.getByLabel('名前',{exact:true}).fill('個人の調査');await dialog.getByLabel('目的・説明').fill('個人の比較検討');await dialog.getByRole('button',{name:'保存',exact:true}).click();await expect(page.getByRole('heading',{name:'個人の調査'})).toBeVisible();
  const projects=page.getByRole('navigation',{name:'プロジェクト一覧',exact:true});
  await projects.getByRole('button',{name:/個人の調査/}).filter({has:page.locator('.sidebar-item-title')}).click();
  await expect(page.getByRole('heading',{name:'個人の調査',exact:true})).toBeVisible();
  await expect(page.locator('main').getByRole('button',{name:/週末の予定を整理/})).toHaveCount(0);
  await page.getByRole('button',{name:'新しいタスク',exact:true}).click();
  await expect(dialog.getByRole('combobox',{name:'プロジェクト',exact:true})).toHaveText('個人の調査');
  await dialog.getByLabel('タイトル',{exact:true}).fill('資料を比較する');
  await dialog.getByLabel('達成したいこと').fill('資料から比較表を作成する');
  await dialog.getByRole('button',{name:'タスクを作成',exact:true}).click();
  await expect(projects.getByRole('button',{name:/資料を比較する/})).toBeVisible();
  await projects.getByRole('button',{name:'個人の調査のタスクを折りたたむ'}).click();
  await expect(projects.getByRole('button',{name:/資料を比較する/})).toHaveCount(0);
  await projects.getByRole('button',{name:'個人の調査のタスクを展開'}).click();
  await projects.getByRole('button',{name:/資料を比較する/}).click();
  await expect(page.getByRole('heading',{name:'資料を比較する',exact:true})).toBeVisible();
  await page.screenshot({path:'.tmp/evidence/sidebar-projects.png',fullPage:true,animations:'disabled'});
  await page.getByRole('button',{name:'Memory',exact:true}).click();await page.getByRole('button',{name:'記憶を追加'}).click();await page.getByLabel('記憶する内容').fill('報告は日本語で簡潔に');await page.getByLabel('根拠・出典').fill('利用者が明示した指示');await page.getByRole('button',{name:'保存して有効化'}).click();await expect(page.getByRole('dialog')).not.toBeVisible();await expect(page.getByText('報告は日本語で簡潔に',{exact:true})).toBeVisible();await page.getByRole('button',{name:'記憶を削除'}).click();await page.getByRole('button',{name:'削除する',exact:true}).click();await expect(page.getByText('報告は日本語で簡潔に',{exact:true})).not.toBeVisible();
});
test('vice president dispatches a project team and preserves the conversation',async({page})=>{
 await page.goto('/');await expect(page.getByRole('heading',{name:'副社長',exact:true})).toBeVisible();await expect(page.getByRole('combobox',{name:'副社長のAI'})).toContainText('Codex');
 await page.getByRole('navigation',{name:'プロジェクト一覧'}).getByRole('button',{name:/個人の調査/}).filter({has:page.locator('.sidebar-item-title')}).click();
 await page.getByRole('combobox',{name:'このプロジェクトのAI'}).click();await page.getByRole('option',{name:'Claude Code · ローカル',exact:true}).click();await expect(page.getByRole('combobox',{name:'このプロジェクトのAI'})).toContainText('Claude Code');
 await page.getByRole('combobox',{name:'このプロジェクトのAI'}).click();await page.getByRole('option',{name:/固定fixture/}).click();await page.getByRole('combobox',{name:'社員数'}).click();await page.getByRole('option',{name:'2人',exact:true}).click();
 await page.getByRole('button',{name:'副社長',exact:true}).click();await page.getByRole('combobox',{name:'副社長のAI'}).click();await page.getByRole('option',{name:/固定fixture/}).click();
 await page.getByRole('textbox',{name:'副社長へのメッセージ'}).fill('資料を整理し、比較メモを作ってください。');await page.getByRole('button',{name:'メッセージを送信'}).click();await expect(page.getByRole('button',{name:'部長に依頼',exact:true})).toBeVisible({timeout:15000});
 await expect(page.getByRole('log').locator('table')).toHaveCount(1);await expect(page.getByRole('log').locator('.katex')).toHaveCount(1);await expect(page.getByRole('log').locator('svg[id^="mermaid"]')).toHaveCount(1,{timeout:20000});await page.screenshot({path:'.tmp/evidence/vice-president.png',fullPage:true,animations:'disabled'});await page.getByRole('button',{name:'部長に依頼',exact:true}).click();await page.getByRole('button',{name:'仕事の進捗を見る'}).click();
 await expect(page.getByRole('heading',{name:'社員の仕事'})).toBeVisible({timeout:15000});await expect(page.getByText('2 / 2 完了',{exact:true})).toBeVisible({timeout:15000});await expect(page.getByRole('button',{name:'確認して受け入れる'})).toBeVisible({timeout:15000});
 await page.screenshot({path:'.tmp/evidence/project-team.png',fullPage:true,animations:'disabled'});await page.getByRole('button',{name:'確認して受け入れる'}).click();await expect(page.getByText('必須の完了条件を確認しました。')).toBeVisible({timeout:10000});await expect(page.getByRole('button',{name:'実行',exact:true})).toHaveCount(0);
 await page.reload();await expect(page.getByRole('log',{name:'副社長との会話'})).toContainText('資料を整理し、比較メモを作ってください。');await expect(page.getByRole('button',{name:'仕事の進捗を見る'})).toBeVisible();await expect(page.getByRole('button',{name:'部長に依頼',exact:true})).toHaveCount(0);
});
test('workspace opens local files, saves through Monaco, and runs a real terminal',async({page})=>{
 const {mkdir,writeFile,readFile}=await import('node:fs/promises'),{resolve,join}=await import('node:path');const folder=resolve('.tmp/ui-workspace');await mkdir(folder,{recursive:true});await writeFile(join(folder,'notes.md'),'# Workspace\n');const errors:string[]=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('/');await page.getByRole('button',{name:'Projects',exact:true}).click();await page.getByRole('button',{name:'プロジェクトを追加'}).click();const dialog=page.getByRole('dialog');await dialog.getByLabel('名前',{exact:true}).fill('開発ワークスペース');await dialog.getByRole('button',{name:'保存',exact:true}).click();await page.getByRole('navigation',{name:'プロジェクト一覧'}).getByRole('button',{name:/開発ワークスペース/}).filter({has:page.locator('.sidebar-item-title')}).click();await page.getByRole('button',{name:'ワークスペース',exact:true}).click();await expect(page.getByRole('checkbox',{name:'社員による開発を有効にする'})).toHaveCount(0);await page.getByLabel('作業フォルダのパス').fill(folder);await page.getByRole('button',{name:'接続して保存'}).click();await page.locator('.file-explorer').getByRole('button',{name:'notes.md',exact:true}).click();await expect(page.locator('.monaco-editor')).toBeVisible();const workspaceBounds=await page.locator('.project-workspace').boundingBox(),editorBounds=await page.locator('.workspace-editor').boundingBox();expect(editorBounds!.width).toBeGreaterThan(workspaceBounds!.width/2);const mainBounds=await page.locator('main').boundingBox();expect(workspaceBounds!.x).toBeCloseTo(mainBounds!.x,0);expect(workspaceBounds!.width).toBeCloseTo(mainBounds!.width,0);expect(workspaceBounds!.y).toBeLessThan(150);expect(workspaceBounds!.y+workspaceBounds!.height).toBeCloseTo(960,0);await page.locator('.monaco-editor textarea').focus();await page.keyboard.press('Meta+A');await page.keyboard.type('# Saved from Monaco\n');await page.getByRole('button',{name:'保存',exact:true}).click();await expect.poll(()=>readFile(join(folder,'notes.md'),'utf8')).toContain('Saved from Monaco');
 await page.getByRole('button',{name:'ターミナル',exact:true}).click();await expect(page.locator('.xterm')).toBeVisible();await page.locator('.xterm-helper-textarea').focus();await page.keyboard.type("printf 'ui-terminal-proof\\n'");await page.keyboard.press('Enter');await expect.poll(async()=>page.locator('.xterm').textContent()).toContain('ui-terminal-proof');await page.screenshot({path:'.tmp/evidence/workspace.png',fullPage:true,animations:'disabled'});await page.setViewportSize({width:760,height:700});await expect(page.locator('body')).toHaveJSProperty('scrollWidth',760);await expect(page.locator('body')).toHaveJSProperty('scrollHeight',700);const narrowEditor=await page.locator('.workspace-editor').boundingBox();expect(narrowEditor!.height).toBeGreaterThan(180);await page.screenshot({path:'.tmp/evidence/workspace-narrow.png',fullPage:true,animations:'disabled'});await page.getByRole('button',{name:'終了',exact:true}).click();await page.setViewportSize({width:1320,height:960});await page.getByRole('button',{name:'ブラウザ',exact:true}).click();await expect(page.getByText('内蔵ブラウザはmacOSアプリで利用できます。',{exact:false})).toBeVisible();expect(errors).toEqual([]);
});

test('native engineer terminal can be launched, answered, detached, reopened and stopped',async({page})=>{
 const {mkdtemp,writeFile}=await import('node:fs/promises'),{join}=await import('node:path'),{tmpdir}=await import('node:os'),{execFile}=await import('node:child_process'),{promisify}=await import('node:util');const exec=promisify(execFile),folder=await mkdtemp(join(tmpdir(),'neura-native-ui-'));
 await exec('/usr/bin/git',['init',folder]);await writeFile(join(folder,'README.md'),'Native CLI fixture');await exec('/usr/bin/git',['-C',folder,'add','.']);await exec('/usr/bin/git',['-C',folder,'-c','user.name=Test','-c','user.email=test@example.invalid','-c','commit.gpgsign=false','commit','-m','base']);
 await page.goto('/');await page.getByRole('button',{name:'Projects',exact:true}).click();await page.getByRole('button',{name:'プロジェクトを追加'}).click();let dialog=page.getByRole('dialog');await dialog.getByLabel('名前',{exact:true}).fill('ネイティブ社員');await dialog.getByRole('button',{name:'保存',exact:true}).click();await expect(dialog).not.toBeVisible();await page.getByRole('navigation',{name:'プロジェクト一覧'}).getByRole('button',{name:/ネイティブ社員/}).filter({has:page.locator('.sidebar-item-title')}).click();await page.getByRole('button',{name:'ワークスペース',exact:true}).click();await page.getByLabel('作業フォルダのパス').fill(folder);await page.getByRole('button',{name:'接続して保存'}).click();
 await page.getByRole('button',{name:'エンジニアを起動',exact:true}).click();dialog=page.getByRole('dialog');await dialog.getByLabel('担当名').fill('UI担当');await dialog.getByLabel('依頼内容').fill('Review this repository');await dialog.getByRole('button',{name:'起動',exact:true}).click();await expect(dialog).not.toBeVisible();await expect(page.locator('.engineer-console .xterm')).toBeVisible();await expect.poll(()=>page.locator('.xterm').textContent()).toContain('NATIVE CLI FIXTURE');await page.locator('.xterm-helper-textarea').focus();await page.keyboard.type('permission-response');await page.keyboard.press('Enter');await expect.poll(()=>page.locator('.xterm').textContent()).toContain('INPUT:permission-response');await page.getByRole('button',{name:'ファイル',exact:true}).click();await page.getByRole('button',{name:'社員の端末',exact:true}).click();await expect.poll(()=>page.locator('.xterm').textContent()).toContain('permission-response');await page.screenshot({path:'.tmp/evidence/native-engineer-fixture.png',fullPage:true});await page.getByRole('button',{name:'終了',exact:true}).click();await expect(page.getByRole('button',{name:'会話を再開'})).toBeVisible({timeout:6000});await page.getByRole('button',{name:'会話を再開'}).click();await expect.poll(()=>page.locator('.xterm').textContent()).toContain('NATIVE CLI FIXTURE');await page.getByRole('button',{name:'終了',exact:true}).click();
});

test('IME confirmation Enter does not send vice president or director chat',async({page})=>{
  const sent:string[]=[];
  page.on('request',request=>{
    if(request.url().endsWith('/api/command')&&request.method()==='POST'){
      const command=request.postDataJSON().command;
      if(command.type==='chat.send')sent.push(command.content);
    }
  });
  await page.goto('/');
  await page.getByRole('button',{name:'Projects',exact:true}).click();
  await page.getByRole('button',{name:'プロジェクトを追加'}).click();
  const dialog=page.getByRole('dialog');
  await dialog.getByLabel('名前',{exact:true}).fill('IME確認');
  await dialog.getByRole('button',{name:'保存',exact:true}).click();
  await expect(dialog).not.toBeVisible();
  await page.getByRole('navigation',{name:'プロジェクト一覧'}).getByRole('button',{name:/IME確認/}).filter({has:page.locator('.sidebar-item-title')}).click();
  await page.getByRole('combobox',{name:'このプロジェクトのAI'}).click();
  await page.getByRole('option',{name:/固定fixture/}).click();
  for(const role of ['部長','副社長']){
    if(role==='副社長'){
      await page.getByRole('button',{name:'副社長',exact:true}).click();
      await page.getByRole('combobox',{name:'副社長のAI'}).click();
      await page.getByRole('option',{name:/固定fixture/}).click();
    }
    const input=page.getByRole('textbox',{name:`${role}へのメッセージ`});
    await input.fill('日本語の変換を確定');
    await input.evaluate(element=>{
      element.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));
      // Normal composition, and IMEs with an unreliable isComposing flag.
      element.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true}));
      element.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
      // WebKit may finish composition before dispatching the same Enter.
      element.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'確定'}));
      element.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));
    });
    await expect(input).toHaveValue('日本語の変換を確定');
    // Give the composition-end protection window time to expire.
    await expect.poll(()=>input.evaluate(()=>performance.now())).toBeGreaterThan(await input.evaluate(()=>performance.now()+60));
    await input.dispatchEvent('keydown',{key:'Enter',keyCode:229,bubbles:true});
    await expect(input).toHaveValue('日本語の変換を確定');
    await input.press('Shift+Enter');
    await expect(input).toHaveValue('日本語の変換を確定\n');
    expect(sent).toHaveLength(role==='部長'?0:1);
    await input.press('Enter');
    await expect(input).toHaveValue('');
    await expect(page.getByRole('button',{name:'応答を停止'})).not.toBeVisible({timeout:15000});
  }
  expect(sent).toEqual(['日本語の変換を確定','日本語の変換を確定']);
  // Leave the default selection intact for the remaining fixture scenarios.
  await page.getByRole('combobox',{name:'副社長のAI'}).click();
  await page.getByRole('option',{name:'Codex · ローカル',exact:true}).click();
});

test('budget stop shows team usage and offers review-only recovery with an explicit allowance',async({page})=>{
 let snapshot:any,command:any;
 await page.route('**/api/state',async route=>{
  if(!snapshot){snapshot=await(await route.fetch()).json();const root=snapshot.state.tasks.find((t:any)=>t.work?.role==='director');expect(root).toBeTruthy();root.title='Review recovery fixture';root.status='blocked';root.reason='team_token_budget';root.work.phase='reviewing';root.runs[0].tokens=70000;}
  await route.fulfill({json:snapshot});
 });
 await page.route('**/api/command',async route=>{
  const value=route.request().postDataJSON().command;if(value.type!=='team.review.resume')return route.continue();command=value;await route.fulfill({json:snapshot.state});
 });
 await page.goto('/');await page.getByRole('navigation',{name:'プロジェクト一覧'}).getByRole('button',{name:/Review recovery fixture/}).click();
 await expect(page.getByText('チームのトークン予算が不足しています。保存済みの成果物は保持されています。')).toBeVisible();
 await expect(page.getByText('チームのトークン数',{exact:true})).toBeVisible();
 await expect(page.getByText('調査はやり直しません。使用済み分を残し、集約用に最大40,000トークン分の予算を確保します。')).toBeVisible();
 await page.getByRole('button',{name:'集約だけ再開',exact:true}).click();
 await expect.poll(()=>command?.type).toBe('team.review.resume');expect(command.additionalTokens).toBe(40000);
});
