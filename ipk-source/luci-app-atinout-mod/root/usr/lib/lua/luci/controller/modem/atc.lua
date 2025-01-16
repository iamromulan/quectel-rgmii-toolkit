local e=require"luci.util"
local e=require"nixio.fs"
local e=require"luci.sys"
local e=require"luci.http"
local e=require"luci.dispatcher"
local e=require"luci.http"
local t=require"luci.sys"
local t=require"luci.model.uci".cursor()
module("luci.controller.modem.atc",package.seeall)
function index()
entry({"admin","modem"},firstchild(),"Modem",30).dependent=false
entry({"admin","modem","atc"},alias("admin","modem","atc","atcommand"),translate("AT Commands"),10).acl_depends={"luci-app-atinout-mod"}
entry({"admin","modem","atc","atcommand"},template("modem/atcommand"),translate("AT Commands"),10)
entry({"admin","modem","atc","atconfig"},cbi("modem/atconfig"),translate("Configuration"),20)
entry({"admin","modem","webcmd"},call("webcmd"))
entry({"admin","modem","atc","user_atc"},call("useratc"),nil).leaf=true
end
function webcmd()
local t=e.formvalue("cmd")
if t then
local t=io.popen("/usr/bin/luci-app-atinout "..t:gsub("[$]","\\\$"):gsub("\"","\\\"").." 2>&1")
local a=t:read("*a")
t:close()
e.write(tostring(a))
else
e.write_json(e.formvalue())
end
end
function uussd(t)
local e=nixio.fs.access("/etc/config/atcommands.user")and
io.popen("cat /etc/config/atcommands.user")
if e then
for a in e:lines()do
local e=a
if e then
t[#t+1]={
usd=e
}
end
end
e:close()
end
end
function useratc()
local e={}
uussd(e)
luci.http.prepare_content("application/json")
luci.http.write_json(e)
end
