import com.example.kazumi.NakuTVColorPolicy;
import com.example.kazumi.NakuTVFlightPath;
import java.util.Arrays;

public final class NakuTVCompatibilityTest {
    private static int checks;
    private static void check(boolean pass, String reason) { checks++; if (!pass) throw new AssertionError(reason); }
    private static int mode(String mime, String codec, int transfer, int range, boolean dv, boolean hdr, boolean hlg) {
        return NakuTVColorPolicy.mode(mime, codec, transfer, range, true, dv, hdr, hlg);
    }
    public static void main(String[] args) {
        check(NakuTVColorPolicy.legacyHuawei("HEGE-570"), "the reported 2019 panel is recognized");
        check(!NakuTVColorPolicy.legacyHuawei("HEGE-570B"), "no blanket assumption for other models");
        check(mode("video/dolby-vision","dvhe.05.06",6,1,false,true,true)==-1,"DV5 cannot fall back to HEVC/PQ");
        check(mode("video/hevc","dvhe.05.06",6,1,false,true,true)==-1,"DV codec string guards mislabeled MIME");
        check(mode("video/dolby-vision","dvhe.05.06",6,1,true,true,true)==3,"actual DV display can use DV5");
        for (String codec : new String[]{"dvhe.07.06","dvh1.08.06"}) {
            check(mode("video/dolby-vision",codec,6,2,false,true,true)==4,"HDR10 base layer remains available");
            check(mode("video/dolby-vision",codec,6,2,false,false,false)==-1,"HDR base layer cannot become SDR by changing labels");
        }
        check(mode("video/dolby-vision","dvh1.08.04",7,2,false,false,true)==4,"HLG compatible layer retained");
        check(mode("video/dolby-vision","dvav.09.06",3,2,false,false,false)==4,"SDR AVC compatible layer retained");
        check(mode("video/dolby-vision","dav1.10.06",6,1,false,true,true)==-1,"AV1 DV ICtCp rejected");
        for(String codecs:new String[]{"", "dvhe.04.06", "not-a-codec"})
            check(mode("video/dolby-vision",codecs,6,2,false,true,true)==-1,"unknown/deprecated DV has no invented fallback");
        check(mode("video/hevc","hvc1.2.4.L153",6,2,false,true,true)==1,"plain HDR10 preserved");
        check(mode("video/hevc","hvc1.2.4.L153",7,2,false,true,true)==2,"plain HLG preserved");
        check(mode("video/avc","avc1.640028",3,2,false,false,false)==0,"SDR remains SDR");
        for(String audio:new String[]{"audio/ac3","audio/eac3","audio/eac3-joc","audio/true-hd","audio/vnd.dts"})
            check(NakuTVColorPolicy.allowDecoder(audio,false,true,false),"DV video rejection must preserve Dolby/DTS/PCM audio decoders");
        check(!NakuTVColorPolicy.allowDecoder("video/dolby-vision",true,false,false),"advertised DV codec blocked without display support");
        check(NakuTVColorPolicy.allowDecoder("video/hevc",true,false,false),"HDR10 hardware decoder preserved");
        check(!NakuTVColorPolicy.allowDecoder("video/hevc",false,true,true),"old television CPU never used for HEVC software fallback");
        NakuTVFlightPath path = new NakuTVFlightPath(31.1443,121.8083,35.7647,140.3864);
        check(path.vertices.length==97*3,"bounded arc work");
        check(Math.abs(path.centerLongitude()-131.1)<2,"first route can face camera");
        float[] a=new float[16], b=new float[16];
        for(int i=0;i<1000;i++) {
            path.frame(i/999.0,Double.NaN,Double.NaN,.5f,a);
            for(float v:a)check(Float.isFinite(v),"finite preview frame");
            for(int column=0;column<3;column++) {
                double norm=0;for(int j=0;j<3;j++)norm+=a[column*4+j]*a[column*4+j];
                check(Math.abs(norm-.25)<1e-5,"orthonormal airframe basis");
            }
        }
        path.frame(.1,33,130,.5f,a);path.frame(.9,33,130,.5f,b);
        check(Arrays.equals(a,b),"reported telemetry never moves as preview progress advances");
        check(Math.abs(Math.sqrt(a[12]*a[12]+a[13]*a[13]+a[14]*a[14])-1.04)<1e-5,"reported model sits above surface");
        path.frame(Double.NaN,Double.NaN,Double.NaN,.5f,a);
        for(float v:a)check(Float.isFinite(v),"invalid preview time is bounded");
        for(double[] bad:new double[][]{{91,0,0,1},{0,181,0,1},{0,0,0,0},{0,0,0,180}}) {
            boolean rejected=false;try {new NakuTVFlightPath(bad[0],bad[1],bad[2],bad[3]);}catch(IllegalArgumentException expected){rejected=true;}
            check(rejected,"invalid/degenerate routes rejected");
        }
        float[] aircraft=NakuTVFlightPath.aircraft();
        check(aircraft.length==1791,"shared native airframe is under 600 vertices");
        for(float v:aircraft)check(Float.isFinite(v) && Math.abs(v)<.1,"original bounded swept-wing geometry");
        System.out.println("PASS "+checks+" TV color/output/airframe checks; no physical-TV playback claim.");
    }
}
