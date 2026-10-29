// Synthetic hostile-to-TERM process tree, no provider/API calls.
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <sys/wait.h>
static void record(const char *path) { int fd=open(path,O_WRONLY|O_CREAT|O_APPEND,0600); dprintf(fd,"%d\n",getpid());close(fd); }
static void work(const char *path) {for(;;){int fd=open(path,O_WRONLY|O_CREAT|O_APPEND,0600);write(fd,"x",1);close(fd);usleep(20000);}}
int main(int argc,char **argv){
 if(argc<4)return 2;
 signal(SIGTERM,SIG_IGN);signal(SIGHUP,SIG_IGN);signal(SIGINT,SIG_IGN);
 record(argv[1]);
 pid_t middle=fork();
 if(middle==0){
   if(strcmp(argv[3],"fast-group")==0){record(argv[1]);execl("/bin/sleep","sleep","30",NULL);_exit(5);}
   if(setsid()<0)_exit(3);
   if(strcmp(argv[3],"detached")==0){pid_t leaf=fork();if(leaf>0)_exit(0);if(leaf<0)_exit(4);}
   record(argv[1]);work(argv[2]);
 }
 if(strcmp(argv[3],"fast-group")==0)return 0;
 if(strcmp(argv[3],"detached")==0)waitpid(middle,NULL,0);
 if(strcmp(argv[3],"exit")==0){usleep(100000);return 7;}
 work(argv[2]);
}
