#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include "mpv/client.h"
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  mpv_handle *p=mpv_create();
  mpv_set_option_string(p,"vo","null");
  mpv_set_option_string(p,"ao","null");
  mpv_set_option_string(p,"pause","yes");
  int hwdec_result=mpv_set_option_string(p,"hwdec","videotoolbox,auto");
  printf("mac_hwdec_option=%d\n",hwdec_result);
  if(hwdec_result<0)return 9;
  if(mpv_initialize(p)<0) return 3;
  const char *load[]={"loadfile",argv[1],NULL};
  if(mpv_command(p,load)<0) return 4;
  int loaded=0;
  for(int i=0;i<100;i++) { mpv_event *e=mpv_wait_event(p,.1); if(e->event_id==MPV_EVENT_FILE_LOADED) {loaded=1;break;} }
  if(!loaded)return 5;
  int64_t width=0,height=0;
  mpv_get_property(p,"width",MPV_FORMAT_INT64,&width);
  mpv_get_property(p,"height",MPV_FORMAT_INT64,&height);
  printf("native_video=%lldx%lld\n",(long long)width,(long long)height);
  const double rates[]={1,2,.5};
  for(int i=0;i<3;i++) {
    mpv_set_property_string(p,"pause","yes");
    const char *seek[]={"seek","2","absolute+exact",NULL};mpv_command(p,seek);
    double rate=rates[i];mpv_set_property(p,"speed",MPV_FORMAT_DOUBLE,&rate);
    char seconds[16];snprintf(seconds,sizeof(seconds),"%.0f",30*rate);
    if(mpv_set_property_string(p,"cache-secs",seconds)<0 ||
       mpv_set_property_string(p,"demuxer-readahead-secs",seconds)<0 ||
       mpv_set_property_string(p,"demuxer-max-bytes","100663296")<0 ||
       mpv_set_property_string(p,"demuxer-max-back-bytes","33554432")<0)return 7;
    int64_t forward=0,backward=0;
    mpv_get_property(p,"demuxer-max-bytes",MPV_FORMAT_INT64,&forward);
    mpv_get_property(p,"demuxer-max-back-bytes",MPV_FORMAT_INT64,&backward);
    if(forward+backward!=134217728)return 8;
    mpv_set_property_string(p,"pause","no");usleep(300000);
    double a=0,b=0,actual=0;mpv_get_property(p,"time-pos",MPV_FORMAT_DOUBLE,&a);
    usleep(2000000);mpv_get_property(p,"time-pos",MPV_FORMAT_DOUBLE,&b);
    mpv_get_property(p,"speed",MPV_FORMAT_DOUBLE,&actual);
    printf("requested=%.2f mpv_speed=%.2f measured=%.2f\n",rate,actual,(b-a)/2);
    if(fabs(actual-rate)>.01 || fabs((b-a)/2-rate)>.35)return 6;
  }
  mpv_terminate_destroy(p);return 0;
}
