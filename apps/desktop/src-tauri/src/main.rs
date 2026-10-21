#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use serde::Deserialize;
use serde_json::Value;
use std::path::PathBuf;
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::oneshot;
#[derive(Default)]
struct ChatSubscriptions(Mutex<HashMap<String,oneshot::Sender<()>>>);
use tauri::{Manager, menu::{Menu, MenuItem}, tray::{TrayIconBuilder, TrayIconEvent, MouseButtonState}};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RunnerRequest { path: String, body: Option<Value> }

fn data_dir() -> Result<PathBuf,String> {
    if let Ok(path)=std::env::var("NEURA_DATA_DIR") {return Ok(PathBuf::from(path));}
    dirs::data_local_dir().map(|p|p.join("neuraOS")).ok_or("data_directory_unavailable".to_string())
}
fn trusted(webview:&tauri::Webview)->Result<(),String>{
 let url=webview.url().map_err(|_|"untrusted_webview")?;
 if webview.label()!="main" || !(url.scheme()=="tauri"&&url.host_str()==Some("localhost") || url.scheme()=="http"&&url.host_str()==Some("tauri.localhost") || cfg!(debug_assertions)&&url.scheme()=="http"&&url.host_str()==Some("127.0.0.1")&&url.port()==Some(1420)){return Err("untrusted_webview".into());}Ok(())
}
fn allowed_path(path:&str,post:bool)->bool {
    if post && ["info","bind","list","read","write","diff","publish","engineer/start","engineer/resume","terminal/open","terminal/poll","terminal/write","terminal/resize","terminal/close"].iter().any(|p|path==format!("/api/workspace/{}",p)){return true;}
    if !post {return path=="/api/state";}
    if ["/api/command","/api/drafts","/api/reconcile","/api/secret","/api/config","/api/login/start","/api/login/poll","/api/enroll","/api/refresh","/api/sources/import"].contains(&path) {return true;}
    let pieces:Vec<&str>=path.split('/').collect();
    pieces.len()==5 && pieces[1]=="api" && pieces[2]=="drafts" && pieces[4]=="publish" && pieces[3].len()==36 && pieces[3].chars().all(|c|c.is_ascii_hexdigit()||c=='-')
}
#[tauri::command]
async fn runner_request(webview:tauri::Webview,request:RunnerRequest)->Result<Value,String>{
    trusted(&webview)?;
    if !allowed_path(&request.path,request.body.is_some()){return Err("request_not_allowed".into());}
    let token=std::fs::read_to_string(data_dir()?.join("runner-token")).map_err(|_|"Runnerが起動していません。".to_string())?;
    let port=std::env::var("NEURA_RUNNER_PORT").ok().and_then(|p|p.parse::<u16>().ok()).unwrap_or(4317);
    let client=reqwest::Client::builder().timeout(std::time::Duration::from_secs(35)).redirect(reqwest::redirect::Policy::none()).build().map_err(|_|"client_failed")?;
    let url=format!("http://127.0.0.1:{}{}",port,request.path);
    let builder=if let Some(body)=request.body{client.post(url).json(&body)}else{client.get(url)};
    let response=builder.bearer_auth(token.trim()).send().await.map_err(|_|"Runnerに接続できません。".to_string())?;
    let status=response.status();let value:Value=response.json().await.map_err(|_|"invalid_response".to_string())?;
    if !status.is_success(){return Err(value.get("message").or_else(||value.get("error")).and_then(|v|v.as_str()).unwrap_or("request_failed").into());}
    Ok(value)
}
#[tauri::command]
async fn runner_chat_stream(webview:tauri::Webview,task_id:String,subscription_id:String,on_event:tauri::ipc::Channel<Value>,subscriptions:tauri::State<'_,ChatSubscriptions>)->Result<(),String>{
    trusted(&webview)?;
    let valid=|id:&str|id.len()==36&&id.chars().all(|c|c.is_ascii_hexdigit()||c=='-');
    if !valid(&task_id)||!valid(&subscription_id){return Err("invalid_subscription".into());}
    let (sender,mut canceled)=oneshot::channel();
    {let mut active=subscriptions.0.lock().map_err(|_|"subscription_failed")?;if active.len()>=32||active.contains_key(&subscription_id){return Err("subscription_limit".into());}active.insert(subscription_id.clone(),sender);}
    let result=async {
        let token=std::fs::read_to_string(data_dir()?.join("runner-token")).map_err(|_|"Runnerが起動していません。".to_string())?;
        let port=std::env::var("NEURA_RUNNER_PORT").ok().and_then(|p|p.parse::<u16>().ok()).unwrap_or(4317);
        let client=reqwest::Client::builder().timeout(std::time::Duration::from_secs(360)).redirect(reqwest::redirect::Policy::none()).build().map_err(|_|"client_failed")?;
        let mut response=client.get(format!("http://127.0.0.1:{}/api/chat/{}/stream",port,task_id)).bearer_auth(token.trim()).send().await.map_err(|_|"stream_connection_failed")?;
        if !response.status().is_success(){return Err("stream_unavailable".to_string());}
        let mut buffer=Vec::new();
        'stream: loop {
            let chunk=tokio::select!{_=&mut canceled=>break, chunk=response.chunk()=>chunk.map_err(|_|"stream_interrupted")?};
            let Some(chunk)=chunk else {break};buffer.extend_from_slice(&chunk);
            if buffer.len()>2*1024*1024{return Err("stream_too_large".into());}
            while let Some(end)=buffer.windows(2).position(|p|p==b"\n\n"){
                let frame:Vec<u8>=buffer.drain(..end+2).collect();let text=std::str::from_utf8(&frame).map_err(|_|"invalid_stream")?;
                for line in text.lines(){if let Some(data)=line.strip_prefix("data: "){
                    if data=="[DONE]"{break 'stream;}
                    let value:Value=serde_json::from_str(data).map_err(|_|"invalid_stream")?;on_event.send(value).map_err(|_|"stream_closed")?;
                }}
            }
        }
        Ok(())
    }.await;
    if let Ok(mut active)=subscriptions.0.lock(){active.remove(&subscription_id);}
    result
}
#[tauri::command]
fn runner_chat_unsubscribe(webview:tauri::Webview,subscription_id:String,subscriptions:tauri::State<'_,ChatSubscriptions>){
    if trusted(&webview).is_err(){return;}
    if let Ok(mut active)=subscriptions.0.lock(){if let Some(sender)=active.remove(&subscription_id){let _=sender.send(());}}
}
#[tauri::command]
async fn open_external_url(webview:tauri::Webview,url:String)->Result<(),String>{
    trusted(&webview)?;
    let parsed=reqwest::Url::parse(&url).map_err(|_|"invalid_url")?;
    if !["https","http"].contains(&parsed.scheme())||parsed.host_str().is_none(){return Err("invalid_url".into());}
    #[cfg(target_os="macos")]
    {std::process::Command::new("/usr/bin/open").arg(parsed.as_str()).spawn().map_err(|_|"open_failed")?;}
    #[cfg(not(target_os="macos"))]
    {return Err("unsupported_platform".into());}
    Ok(())
}
#[tauri::command]
async fn choose_workspace_folder(webview:tauri::Webview)->Result<Option<String>,String>{
 trusted(&webview)?;
 tauri::async_runtime::spawn_blocking(||{let result=std::process::Command::new("/usr/bin/osascript").args(["-e","POSIX path of (choose folder with prompt \"プロジェクトの作業フォルダを選択\")"]).output().map_err(|_|"folder_dialog_failed".to_string())?;if !result.status.success(){return Ok(None);}Ok(Some(String::from_utf8_lossy(&result.stdout).trim().to_string()))}).await.map_err(|_|"folder_dialog_failed".to_string())?
}
#[tauri::command]
async fn workspace_browser(webview:tauri::Webview,app:tauri::AppHandle,action:String,url:Option<String>,x:Option<f64>,y:Option<f64>,width:Option<f64>,height:Option<f64>,viewport_height:Option<f64>)->Result<Value,String>{
 trusted(&webview)?;
 let browser=app.get_webview("workspace-browser");
 if action=="hide" {if let Some(b)=browser{b.hide().map_err(|e|e.to_string())?;}return Ok(Value::Null);}
 let origin=webview.position().map_err(|e|e.to_string())?;let scale=webview.window().scale_factor().map_err(|e|e.to_string())?;
 #[cfg(target_os="macos")]
 // WKWebView may inset its DOM viewport below the macOS title bar.
 let title_offset=(webview.size().map_err(|e|e.to_string())?.height as f64/scale-viewport_height.unwrap_or(webview.size().map_err(|e|e.to_string())?.height as f64/scale)).clamp(0.0,100.0);
 #[cfg(not(target_os="macos"))]
 let title_offset=0.0;
 let bounds=||->Result<(tauri::LogicalPosition<f64>,tauri::LogicalSize<f64>),String>{let (x,y,w,h)=(x.unwrap_or(0.0),y.unwrap_or(0.0),width.unwrap_or(0.0),height.unwrap_or(0.0));if ![x,y,w,h].iter().all(|v|v.is_finite())||x<0.0||y<0.0||w<10.0||h<10.0||w>10000.0||h>10000.0{return Err("invalid_bounds".into());}Ok((tauri::LogicalPosition::new(x+origin.x as f64/scale,y+origin.y as f64/scale+title_offset),tauri::LogicalSize::new(w,h)))};
 let target=||->Result<reqwest::Url,String>{let parsed=reqwest::Url::parse(url.as_deref().unwrap_or("https://example.com")).map_err(|_|"invalid_url")?;if !["http","https"].contains(&parsed.scheme())||parsed.host_str().is_none(){return Err("invalid_url".into());}Ok(parsed)};
 if action=="open"&&browser.is_none(){let (position,size)=bounds()?;let builder=tauri::webview::WebviewBuilder::new("workspace-browser",tauri::WebviewUrl::External(target()?)).on_navigation(|url|["http","https"].contains(&url.scheme())).on_new_window(|_,_|tauri::webview::NewWindowResponse::Deny);app.get_window("main").ok_or("window_missing")?.add_child(builder,position,size).map_err(|e|e.to_string())?;return Ok(Value::Null);}
 let b=browser.ok_or("browser_missing")?;
 match action.as_str(){"open"|"bounds"=>{let (position,size)=bounds()?;b.set_bounds(tauri::Rect{position:position.into(),size:size.into()}).map_err(|e|e.to_string())?;b.show().map_err(|e|e.to_string())?;},"navigate"=>b.navigate(target()?).map_err(|e|e.to_string())?,"back"=>b.eval("history.back()").map_err(|e|e.to_string())?,"forward"=>b.eval("history.forward()").map_err(|e|e.to_string())?,"reload"=>b.eval("location.reload()").map_err(|e|e.to_string())?,"state"=>{},_=>return Err("invalid_browser_action".into())};
 Ok(serde_json::json!({"url":b.url().map_err(|e|e.to_string())?.as_str()}))
}
#[tauri::command]
async fn workspace_browser_capture(webview:tauri::Webview,app:tauri::AppHandle)->Result<Value,String>{
 trusted(&webview)?;let b=app.get_webview("workspace-browser").ok_or("browser_missing")?;
 let (sender,receiver)=oneshot::channel();let sender=Mutex::new(Some(sender));
 b.eval_with_callback("({url:location.href,title:document.title,text:(window.getSelection()?.toString()||document.body.innerText).slice(0,20000)})",move|result|{if let Ok(mut sender)=sender.lock(){if let Some(sender)=sender.take(){let _=sender.send(result);}}}).map_err(|e|e.to_string())?;
 let value=tokio::time::timeout(std::time::Duration::from_secs(5),receiver).await.map_err(|_|"capture_timeout")?.map_err(|_|"capture_failed")?;
 serde_json::from_str(&value).map_err(|_|"capture_failed".into())
}
fn main(){
    tauri::Builder::default().manage(ChatSubscriptions::default()).invoke_handler(tauri::generate_handler![runner_request,runner_chat_stream,runner_chat_unsubscribe,open_external_url,choose_workspace_folder,workspace_browser,workspace_browser_capture])
    .setup(|app|{
        let show=MenuItem::with_id(app,"show","neuraOSを開く",true,None::<&str>)?;
        let quit=MenuItem::with_id(app,"quit","ウィンドウを終了（Runnerは継続）",true,None::<&str>)?;
        let menu=Menu::with_items(app,&[&show,&quit])?;
        let mut pixels=vec![0u8;32*32*4];
        for y in 0..32 {for x in 0..32 {let i=(y*32+x)*4;let on=(x>=7&&x<=11&&y>=9&&y<=25)||(x>=20&&x<=24&&y>=13&&y<=25)||(x>=11&&x<=21&&y>=9&&y<=13);if on{pixels[i]=36;pixels[i+1]=52;pixels[i+2]=73;pixels[i+3]=255;}}}
        let icon=tauri::image::Image::new_owned(pixels,32,32);
        TrayIconBuilder::new().icon(icon).icon_as_template(true).tooltip("neuraOS · Runnerは独立して動作します").menu(&menu)
            .on_menu_event(|app,event|match event.id.as_ref(){"show"=>{if let Some(w)=app.get_webview_window("main"){let _=w.show();let _=w.set_focus();}},"quit"=>app.exit(0),_=>{}})
            .on_tray_icon_event(|tray,event|{if let TrayIconEvent::Click{button_state:MouseButtonState::Up,..}=event{if let Some(w)=tray.app_handle().get_webview_window("main"){let _=w.show();let _=w.set_focus();}}}).build(app)?;
        Ok(())
    })
    .on_window_event(|window,event|{if let tauri::WindowEvent::CloseRequested{api,..}=event{api.prevent_close();let _=window.hide();}})
    .run(tauri::generate_context!()).expect("neuraOS could not start");
}
