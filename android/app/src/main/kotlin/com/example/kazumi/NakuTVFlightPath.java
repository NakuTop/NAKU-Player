package com.example.kazumi;

/** Great-circle route and local airframe basis. All animation scratch is caller-owned. */
public final class NakuTVFlightPath {
    private final double[] from, to;
    private final double angle, sinAngle, height;
    public final float[] vertices;
    public NakuTVFlightPath(double fromLat, double fromLon, double toLat, double toLon) {
        if (!valid(fromLat, fromLon) || !valid(toLat, toLon)) throw new IllegalArgumentException();
        from = point(fromLat, fromLon); to = point(toLat, toLon);
        angle = Math.acos(Math.max(-1, Math.min(1, dot(from, to))));
        if (angle < 1e-6 || Math.PI - angle < 1e-6) throw new IllegalArgumentException();
        sinAngle = Math.sin(angle);
        height = Math.max(.035, Math.min(.16, angle * .11));
        vertices = new float[97 * 3];
        for (int i = 0; i <= 96; i++) {
            double t = i / 96.0, a = Math.sin((1 - t) * angle) / sinAngle,
                    b = Math.sin(t * angle) / sinAngle, radius = 1.012 + Math.sin(t * Math.PI) * height;
            for (int axis = 0; axis < 3; axis++) vertices[i * 3 + axis] = (float)((from[axis]*a + to[axis]*b) * radius);
        }
    }
    public static boolean valid(double lat, double lon) {
        return Double.isFinite(lat) && Math.abs(lat) <= 90 && Double.isFinite(lon) && Math.abs(lon) <= 180;
    }
    private static double[] point(double lat, double lon) {
        double a = Math.toRadians(lat), b = Math.toRadians(lon);
        return new double[]{Math.cos(a)*Math.sin(b), Math.sin(a), Math.cos(a)*Math.cos(b)};
    }
    private static double dot(double[] a, double[] b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
    public float centerLongitude() { return (float)Math.toDegrees(Math.atan2(from[0]+to[0], from[2]+to[2])); }

    /** Preview movement is visual only; reported positions never advance with time. */
    public void frame(double progress, double reportedLat, double reportedLon, float scale, float[] out) {
        double x, y, z, radius;
        if (valid(reportedLat, reportedLon)) {
            double a = Math.toRadians(reportedLat), b = Math.toRadians(reportedLon);
            x = Math.cos(a)*Math.sin(b); y = Math.sin(a); z = Math.cos(a)*Math.cos(b);
            radius = 1.04;
        } else {
            double t = Double.isFinite(progress) ? Math.max(.001, Math.min(.999, progress)) : .5;
            double a = Math.sin((1-t)*angle)/sinAngle, b = Math.sin(t*angle)/sinAngle;
            x = from[0]*a+to[0]*b; y = from[1]*a+to[1]*b; z = from[2]*a+to[2]*b;
            radius = 1.018 + Math.sin(t*Math.PI)*height;
        }
        double dot = to[0]*x+to[1]*y+to[2]*z;
        double fx=to[0]-dot*x, fy=to[1]-dot*y, fz=to[2]-dot*z;
        double length=Math.sqrt(fx*fx+fy*fy+fz*fz);
        if (length < 1e-6) { fx=x*y; fy=-(x*x+z*z); fz=z*y; length=Math.sqrt(fx*fx+fy*fy+fz*fz); }
        if (length < 1e-6) { fx=1; fy=0; fz=0; length=1; }
        fx/=length; fy/=length; fz/=length;
        out[0]=(float)((y*fz-z*fy)*scale); out[1]=(float)((z*fx-x*fz)*scale); out[2]=(float)((x*fy-y*fx)*scale); out[3]=0;
        out[4]=(float)(x*scale); out[5]=(float)(y*scale); out[6]=(float)(z*scale); out[7]=0;
        out[8]=(float)(fx*scale); out[9]=(float)(fy*scale); out[10]=(float)(fz*scale); out[11]=0;
        out[12]=(float)(x*radius); out[13]=(float)(y*radius); out[14]=(float)(z*radius); out[15]=1;
    }

    /** Same swept-wing airliner dimensions as Home Display's createAircraftGeometry. */
    public static float[] aircraft() {
        float[] wings = {
            0,.002f,.024f, -.070f,.002f,-.024f, -.067f,.002f,-.037f,
            0,.002f,.024f, -.067f,.002f,-.037f, 0,.002f,-.016f,
            0,.002f,.024f, 0,.002f,-.016f, .067f,.002f,-.037f,
            0,.002f,.024f, .067f,.002f,-.037f, .070f,.002f,-.024f,
            0,.004f,-.042f, -.027f,.004f,-.068f, 0,.004f,-.063f,
            0,.004f,-.042f, 0,.004f,-.063f, .027f,.004f,-.068f,
            0,.006f,-.036f, 0,.030f,-.066f, 0,.006f,-.066f
        };
        float[] result = new float[(12*8*6+21)*3]; int at=0;
        for (int row=0;row<8;row++) for(int col=0;col<12;col++) {
            int[][] corners={{row,col},{row+1,col},{row,col+1},{row,col+1},{row+1,col},{row+1,col+1}};
            for (int[] c:corners) {
                double latitude=Math.PI*c[0]/8, longitude=Math.PI*2*c[1]/12;
                result[at++]=(float)(Math.sin(latitude)*Math.sin(longitude)*.009);
                result[at++]=(float)(Math.cos(latitude)*.008);
                result[at++]=(float)(Math.sin(latitude)*Math.cos(longitude)*.072);
            }
        }
        System.arraycopy(wings,0,result,at,wings.length); return result;
    }
}
