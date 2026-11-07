import numpy as np, sys
from PIL import Image
N=int(sys.argv[1]) if len(sys.argv)>1 else 768
rng=np.random.default_rng(int(sys.argv[2]) if len(sys.argv)>2 else 4)
def pnoise(scale, power=2.0):
    # periodic noise via FFT-filtered white noise (tiles seamlessly)
    f=np.fft.fftfreq(N)[:,None]**2+np.fft.fftfreq(N)[None,:]**2
    f[0,0]=1; amp=1/(f**(power/2)); amp[0,0]=0
    amp*=np.exp(-f*(N/scale)**2*0.0)  # keep
    lp=np.exp(-f*(N/scale)**2)        # low-pass by feature size
    z=np.fft.ifft2(np.fft.fft2(rng.standard_normal((N,N)))*amp*lp).real
    z-=z.min(); return z/z.max()
y,x=np.mgrid[0:N,0:N].astype(float)
def edges(cells, warp, wscale):
    # Voronoi F2-F1 with wraparound, domain-warped at two scales (bends + wobble)
    wx=(pnoise(wscale)-.5)*warp+(pnoise(wscale*6)-.5)*warp*0.22; wy=(pnoise(wscale)-.5)*warp+(pnoise(wscale*6)-.5)*warp*0.22
    X=(x+wx)%N; Y=(y+wy)%N
    g=N/cells; pts=[]
    for i in range(cells):
        for j in range(cells):
            pts.append(((i+rng.uniform(.15,.85))*g,(j+rng.uniform(.15,.85))*g))
    f1=np.full((N,N),1e9); f2=np.full((N,N),1e9)
    for px,py in pts:
        dx=np.abs(X-px); dx=np.minimum(dx,N-dx); dy=np.abs(Y-py); dy=np.minimum(dy,N-dy)
        d=np.sqrt(dx*dx+dy*dy)
        f2=np.where(d<f1,f1,np.minimum(f2,d)); f1=np.minimum(f1,d)
    return f2-f1
def smooth(a,b,t): t=np.clip((t-a)/(b-a),0,1); return t*t*(3-2*t)
big=edges(5,260,7); small=edges(13,160,10)
wvar=0.35+1.9*pnoise(6)**1.5                # vein thickness varies a lot
fat_big=1-smooth(2.0*wvar,7.5*wvar,big)
fat_small=(1-smooth(0.6,2.6,small))*smooth(0.55,0.8,pnoise(5))*0.8
flecks=smooth(0.86,0.9,pnoise(120,1.2))*smooth(0.55,0.7,pnoise(5))*0.9
fat=np.clip(np.maximum(np.maximum(fat_big,fat_small),flecks),0,1)
# muscle tones
t=pnoise(4); t2=pnoise(18)
deep=np.array([92,8,16]); mid=np.array([155,20,30]); hi=np.array([205,48,58])
tone=np.clip((t-0.5)*1.5+0.5+(t2-0.5)*0.45,0,1)[...,None]
muscle=np.where(tone<.5, deep+(mid-deep)*(tone/.5), mid+(hi-mid)*((tone-.5)/.5))
# fibers: fine streaks, slightly darker cracks near veins
fib=pnoise(140,1.2); grain=edges(46,30,30); crev=smooth(0,3.5,grain)
muscle=muscle*(0.95+0.05*crev[...,None])*(0.9+0.16*fib[...,None])
near=(1-smooth(0,10,big))[...,None]*0.18; muscle=muscle*(1-near)
fatc=np.array([246,232,224])*(0.92+0.1*pnoise(30)[...,None])
pinkedge=np.array([232,150,150])
f=fat[...,None]
col=muscle*(1-f)+ (pinkedge*(1-f)+fatc*f)*f
Image.fromarray(np.clip(col,0,255).astype(np.uint8)).save(sys.argv[3] if len(sys.argv)>3 else 'meat.png')
