use neura_native_core::{process_tree,workspace};
#[tokio::test]
async fn bounded_native_runner_reaps_children_on_limit_timeout_and_cancel(){
 let dir=std::env::temp_dir().join(format!("neura-runner-{}",uuid::Uuid::new_v4()));std::fs::create_dir(&dir).unwrap();
 process_tree::ensure_supervisor(std::path::Path::new(env!("CARGO_BIN_EXE_neura-native-core")),&dir.join("owner.lock")).await.unwrap();
 for script in ["import sys;sys.stdout.write('x'*5000000)","import sys;sys.stderr.write('x'*100000)"]{
  let e=workspace::run("/tmp","/usr/bin/python3",&["-c",script],5).await.unwrap_err();assert_eq!(e.error,"output_too_large");
 }
 assert_eq!(workspace::run("/tmp","/usr/bin/python3",&["-c","import sys;sys.stderr.write('x'*50000);print('ok')"],5).await.unwrap(),"ok\n");
 let pidfile=dir.join("child.pid");let source=format!("import os,time\npid=os.fork()\nif pid==0:\n os.setsid()\n open({:?},'w').write(str(os.getpid()))\n time.sleep(60)\nelse:\n time.sleep(60)\n",pidfile.to_string_lossy());
 let error=workspace::run("/tmp","/usr/bin/python3",&["-c",&source],1).await.unwrap_err();assert_eq!(error.error,"operation_timeout");
 let pid=std::fs::read_to_string(&pidfile).unwrap().parse::<i32>().unwrap();assert_eq!(unsafe{libc::kill(pid,0)},-1);assert_eq!(std::io::Error::last_os_error().raw_os_error(),Some(libc::ESRCH));
 let cancel_pid=dir.join("cancel.pid");let source=format!("import os,time\nopen({:?},'w').write(str(os.getpid()))\ntime.sleep(60)\n",cancel_pid.to_string_lossy());
 let task=tokio::spawn(async move{workspace::run("/tmp","/usr/bin/python3",&["-c",&source],30).await});
 tokio::time::timeout(std::time::Duration::from_secs(5),async{while !cancel_pid.exists(){tokio::time::sleep(std::time::Duration::from_millis(10)).await;}}).await.unwrap();let pid=std::fs::read_to_string(&cancel_pid).unwrap().parse::<i32>().unwrap();task.abort();let _=task.await;
 tokio::time::timeout(std::time::Duration::from_secs(5),async{while unsafe{libc::kill(pid,0)}==0{tokio::time::sleep(std::time::Duration::from_millis(20)).await;}}).await.unwrap();
 let _=std::fs::remove_dir_all(dir);
}
