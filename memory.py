#无恶意开关机 无恶意重复
import turtle as t
import time
import webbrowser
import sys

x=0
t.up()
Ans="林聪说他想跳舞！"
a=len(Ans)
#每个汉字都会向后退x步
t.bk(a*25)
for i in range(3):
    t.write(Ans[x],font=("汉仪文黑-85W",30,"normal"))
    t.fd(50)    
    time.sleep(0.5)
    x=x+1
    
sys.path.append("libs") 
url = 'https://www.bilibili.com/video/BV1fv411t7zV?t=23.5'
webbrowser.open(url)

for d in range(a-3):
    t.write(Ans[x],font=("汉仪文黑-85W",30,"normal"))
    t.fd(50)
    time.sleep(0.01)
    x=x+1
time.sleep(60)
url = 'https://www.bilibili.com/video/BV1TJ411q7Zs?t=14.6'
webbrowser.open(url)




#t.bgpic(r"C:\Users\LENOVO\AppData\Local\Programs\Python\Python36-32\pic\2.png")

