dofile('server/helpers/main.lua')
local labels={[7]='Lang A',[8]='Lang B'}
Feather={Locale={translate=function(src,key,...)
 if key=='err_native_recovery_audit_pending' and labels[src] then return labels[src] end
 if key=='msg_move_partial' and labels[src] then return string.format(labels[src]..' moved %d skipped %d: %s',...) end
 return 'Translation ['..key..'] is unavailable'
end}}
local result={error=true,code='denied',message='native_recovery_audit_pending'}
assert(TranslateResult(7,result,'err_give_failed')=='Lang A')
assert(TranslateResult(8,result,'err_give_failed')=='Lang B')
labels[7]='Changed language'
assert(TranslateResult(7,result)=='Changed language')
assert(TranslateResult(9,result)=='This item is held for recovery verification. Ask an administrator to inspect it.')
assert(Translate(9,'missing','English')=='English')
assert(result.message=='native_recovery_audit_pending','recipient resolution must not rewrite shared results')
local skipped={movedCount=0,skippedCount=1,skipReason='native_recovery_audit_pending',
 message='Moved 0; skipped 1. native_recovery_audit_pending'}
assert(TranslateResult(8,skipped)=='Lang B moved 0 skipped 1: Lang B')
local missing=TranslateResult(9,skipped)
assert(missing=='Moved 0; skipped 1. This item is held for recovery verification. Ask an administrator to inspect it.')
assert(not missing:find('native_recovery_audit_pending',1,true))
print('PASS recipient language resolution after guard, live selected-language change and missing dictionary English fallback')

-- Exercise the real client import adapter, not an optimistic translator stub.
-- Provider errors turn into the same sentinel seen by a live NUI label refresh.
local providerFailed=false
exports={['feather-core']={TranslateLocale=function(_,src,key)
 assert(src==0)
 if providerFailed then return {ok=false} end
 return {ok=true,value=key=='known' and 'Selected language' or 'Locale [missing] does not exist'}
end}}
dofile('client/imports.lua')
dofile('client/helpers/main.lua')
assert(Translate('known','English')=='Selected language')
assert(Translate('missing','English')=='English')
providerFailed=true
assert(Translate('known','English')=='English','provider-unavailable sentinel cannot replace the English fallback')
assert(Translate('known',nil)==nil,'NUI missing key stays absent so its English defaults apply')
print('PASS actual client import/helper fallback and provider-formatted partial-move recipient messages')
