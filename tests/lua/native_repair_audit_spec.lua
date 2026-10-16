Result={Err=function(code,message) return {ok=false,error={code=code,message=message}} end,
 Ok=function(value) return {ok=true,value=value} end}
dofile('server/services/native_repair_audit.lua')
local active=true
local before={characterId='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb',items={[112]={id=112,revision=1,metadata={condition=50}}}}
local spec={characterId=before.characterId,itemRevision=1,before={condition=50}}
local files,encoded={},{}
local nextToken,plans,reads=0,0,0
NativeRepairVerify={Compare=function(old,new,intent)
 assert(old.items[112].id==112 and new==before and intent.characterId==before.characterId)
 return Result.Ok({verified=true})
end}
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function copy(v)
 if type(v)~='table' then return v end
 local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local api={enabled=function() return true end,context=function() return 'session' end,
 current=function() return active end,
 plan=function() plans=plans+1; return Result.Ok(spec) end,
 read=function() reads=reads+1; return Result.Ok(before) end,
 equal=equal,
 encode=function(value) nextToken=nextToken+1; local token='encoded-'..nextToken; encoded[token]=copy(value); return token end,
 decode=function(value) return copy(encoded[value]) end,
 load=function(name) return files[name] end,
 save=function(name,value) files[name]=value; return true end,
}
local audit=NativeRepairAudit.New(api)
assert(audit.Run(2,before.characterId,112,'capture').ok)
assert(plans==1 and reads==1)
assert(not audit.Run(2,before.characterId,112,'capture').ok and plans==1,'never overwrite baseline')
-- New instance models restart: retained file, not an in-memory baseline cache.
local restarted=NativeRepairAudit.New(api)
assert(restarted.Run(2,before.characterId,112,'verify').ok and plans==1)
assert(restarted.Run(2,before.characterId,112,'inspect').ok)
active=false; assert(not restarted.Run(2,before.characterId,112,'verify').ok)
active=true
assert(not audit.Run(2,'../../outside',112,'capture').ok)
assert(not audit.Run(2,before.characterId,113,'verify').ok)
local retained=next(files); files[retained]='corrupt'
assert(not audit.Run(2,before.characterId,112,'verify').ok)
files={}; api.save=function() return false end
assert(not audit.Run(2,before.characterId,112,'capture').ok)
files={}; api.save=function(name,value) files[name]=value; return 1 end
assert(audit.Run(2,before.characterId,112,'capture').ok,'numeric native true plus exact readback accepted')
files={}; api.save=function(name,value) files[name]=value; return false end
assert(not audit.Run(2,before.characterId,112,'capture').ok)
assert(audit.Run(2,before.characterId,112,'inspect').ok,'false ack still leaves valid file inspectable without overwrite')
local record=encoded[files[next(files)]]
record.before.items[112].revision=2
assert(not audit.Run(2,before.characterId,112,'inspect').ok,'changed retained state cannot pass inspection')
print('native_repair_audit_spec PASS (persistent capture/restart verify, no overwrite, current context, corruption/path/save refusal; mocked file/SQL boundary)')
files={}; api.save=function(name,value) files[name]=value; return true end
api.wearPlan=api.plan
NativeRepairVerify.CompareWear=function(old,new,intent)
 assert(old.items[112].revision==1 and intent.characterId==before.characterId); return Result.Ok({wear=true})
end
assert(audit.Run(2,before.characterId,112,'capture-wear').ok)
assert(audit.Run(2,before.characterId,112,'verify-wear').ok)
assert(next(files):find('.native-wear-audit-',1,true),'wear baseline must not overwrite repair baseline')
