import math
WOOL="#ffffff"; FACE="#dcb892"; EAR="#cda277"; EARIN="#b88f63"; DARK="#5b4a3d"; EYE="#1a1a1a"; LINE="#000000"; LW=2.2

def scallop(cx, cy, rx, ry, n, bulge=1.2, phase=-math.pi/2):
    pts=[(cx+rx*math.cos(2*math.pi*i/n+phase), cy+ry*math.sin(2*math.pi*i/n+phase)) for i in range(n)]
    d=f"M {pts[0][0]:.2f},{pts[0][1]:.2f} "
    for i in range(n):
        x,y=pts[(i+1)%n]; chord=math.dist(pts[i],pts[(i+1)%n]); rad=chord/2*bulge
        d+=f"A {rad:.2f},{rad:.2f} 0 0 1 {x:.2f},{y:.2f} "
    return d+"Z"
def almond(a,h): return f"M{-a},0 Q0,{-2*h} {a},0 Q0,{2*h} {-a},0 Z"

svg=f'''<svg id="emoji" viewBox="0 0 72 72" xmlns="http://www.w3.org/2000/svg">
  <g stroke="{LINE}" stroke-width="{LW}" stroke-linejoin="round" stroke-linecap="round">
    <path d="M22,38 Q5,34 1.5,46 Q12,49 21,44 Z" fill="{EAR}"/>
    <path d="M50,38 Q67,34 70.5,46 Q60,49 51,44 Z" fill="{EAR}"/>
    <path d="M16,40 Q8,42 5,46" fill="none" stroke="{EARIN}" stroke-width="1.6"/>
    <path d="M56,40 Q64,42 67,46" fill="none" stroke="{EARIN}" stroke-width="1.6"/>
    <path d="{scallop(36, 33, 23, 23, 11)}" fill="{WOOL}"/>
    <path d="M36,27.5 C44.5,27.5 47.5,35 46.5,42.5 C45.8,49.5 41.5,53 36,53 C30.5,53 26.2,49.5 25.5,42.5 C24.5,35 27.5,27.5 36,27.5 Z" fill="{FACE}"/>
    <path transform="translate(31,38) rotate(12)" d="{almond(3.1,2.05)}" fill="{EYE}" stroke="none"/>
    <path transform="translate(41,38) rotate(-12)" d="{almond(3.1,2.05)}" fill="{EYE}" stroke="none"/>
    <path d="M33,42.4 Q36,40.7 39,42.4 Q37.9,45.2 36,47 Q34.1,45.2 33,42.4 Z" fill="{DARK}" stroke-width="1.8"/>
    <path d="M36,47 L36,48.7" fill="none"/>
    <path d="M36,48.7 Q31.2,51.2 30.2,48.8" fill="none"/>
    <path d="M36,48.7 Q40.8,51.2 41.8,48.8" fill="none"/>
  </g>
</svg>'''
open("art/avatars/sheep_face.svg","w").write(svg); print("ok")
