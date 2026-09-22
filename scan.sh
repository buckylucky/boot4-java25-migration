#!/usr/bin/env bash
# Spring Boot 2.6 -> 4.1 / Java 25 migration - Phase 0 inventory scanner
#
# Usage (at the ROOT of the service repo):
#   bash scan.sh              # summary + work list
#   bash scan.sh -v           # file:line detail per finding
#
# The output IS your work list. Skip the exploration tour; do what this script says.
# Each label maps to an entry in SKILL.md's "Known errors" catalog.
set -uo pipefail
V=0; [ "${1:-}" = "-v" ] && V=1
J=(--include=*.java); R=(--include=*.yml --include=*.yaml --include=*.properties)
SRC=${SRC:-src}
have() { command -v "$1" >/dev/null 2>&1; }

hdr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
FINDINGS=0
item() { # item <label> <count> <hint>
  local n=${2//[^0-9]/}; n=${n:-0}
  if [ "$n" -gt 0 ]; then
    printf '  \033[33m%-4s\033[0m %-52s %s\n' "$n" "$1" "$3"
    FINDINGS=$((FINDINGS+1))
    if [ "$V" = 1 ] && [ -s "$TMPM" ]; then sed 's/^/        /' "$TMPM" | head -40; fi
  else
    printf '  %-4s %-52s\n' "-" "$1"
  fi
  : > "$TMPM"
}
# -v support: cnt/occ write matches to $TMPM, item prints and clears it.
TMPM="${TMPDIR:-/tmp}/scan-matches.$$"
: > "$TMPM"
trap 'rm -f "$TMPM"' EXIT
cnt() { local out; out=$(grep -rl "$@" 2>/dev/null); [ "$V" = 1 ] && printf '%s\n' "$out" > "$TMPM"
        printf '%s' "$out" | grep -c . | tr -d ' '; }
occ() { local out; out=$(grep -rn "$@" 2>/dev/null); [ "$V" = 1 ] && printf '%s\n' "$out" > "$TMPM"
        printf '%s' "$out" | grep -c . | tr -d ' '; }

echo "repo: $(basename "$PWD")   src: $SRC"

# ---------------------------------------------------------------- 1. COMPILE
hdr "1. COMPILE BREAKERS - the recipe does most; check what remains by hand"
item "files importing javax.*"              "$(cnt -E 'import javax\.(servlet|persistence|validation|annotation|ws\.rs)' "${J[@]}" "$SRC")"        "recipe: JakartaEE10"
item "files using javax.ws.rs"              "$(cnt 'javax.ws.rs' "${J[@]}" "$SRC")"                                                                 "MANUAL: add HttpStatus to ResponseStatusException ctor"
item "org.apache.commons.lang (2.x)"        "$(cnt 'org.apache.commons.lang\.' "${J[@]}" "$SRC")"                                                   "recipe: UpgradeApacheCommonsLang_2_3"
item "shaded lang3 import accident (logstash)" "$(cnt 'net.logstash.logback.encoder.org' "${J[@]}" "$SRC")"                                          "recipe: ChangePackage"
item "org.codehaus.jackson (Jackson 1.x)"   "$(cnt 'org.codehaus.jackson' "${J[@]}" "$SRC")"                                                        "recipe: ChangePackage"
item "org.apache.axis"                      "$(cnt 'org.apache.axis' "${J[@]}" "$SRC")"                                                             "MANUAL: local TeeOutputStream"
item "org.apache.http (HttpClient 4)"       "$(cnt 'org.apache.http\.' "${J[@]}" "$SRC")"                                                            "recipe: UpgradeApacheHttpClient_5"
item "WebSecurityConfigurerAdapter"         "$(cnt 'WebSecurityConfigurerAdapter' "${J[@]}" "$SRC")"                                                 "recipe (VERIFY the diff!)"
item "antMatchers/mvcMatchers/authorizeRequests" "$(cnt -E 'antMatchers|mvcMatchers|authorizeRequests' "${J[@]}" "$SRC")"                            "recipe: AuthorizeHttpRequests + UseNewRequestMatchers"
item "getCellTypeEnum (POI)"                "$(cnt 'getCellTypeEnum' "${J[@]}" "$SRC")"                                                              "recipe: ChangeMethodName"
item "getStatusCodeValue/getMethodValue"    "$(cnt -E 'getStatusCodeValue|getMethodValue' "${J[@]}" "$SRC")"                                          "MANUAL: getStatusCode().value() / getMethod().name()"
item "ListenableFuture"                     "$(cnt 'ListenableFuture' "${J[@]}" "$SRC")"                                                             "MANUAL: CompletableFuture"
item ".completable() (KafkaTemplate)"       "$(cnt '\.completable()' "${J[@]}" "$SRC")"                                                              "recipe: RemoveUsingCompletableFuture"
item "HttpServletResponse/RequestWrapper"   "$(cnt -E 'implements HttpServletResponse|extends HttpServletResponseWrapper|extends HttpServletRequestWrapper' "${J[@]}" "$SRC")" "MANUAL: Servlet 6.1 signature changes"
item "org.springframework.util.StringUtils" "$(cnt 'org.springframework.util.StringUtils' "${J[@]}" "$SRC")"                                          "MANUAL: isEmpty REMOVED -> !hasLength/!hasText"
item "  ^ of those, isEmpty( callers"       "$(grep -rl 'org.springframework.util.StringUtils' "${J[@]}" "$SRC" 2>/dev/null | xargs -r grep -l 'StringUtils.isEmpty(' 2>/dev/null | wc -l | tr -d ' ')" "REAL breakage is ONLY these"
item "SpringExtension + @Mock in one class" "$(grep -rl 'SpringExtension' "${J[@]}" "$SRC" 2>/dev/null | xargs -r grep -l '@Mock' 2>/dev/null | wc -l | tr -d ' ')" "MANUAL: switch to MockitoExtension"
item "old spring-kafka error handlers"      "$(cnt -E 'SeekToCurrentErrorHandler|setErrorHandler|implements ErrorHandler|RetryTemplate' "${J[@]}" "$SRC")" "MANUAL: CommonErrorHandler/DefaultErrorHandler"

# ---------------------------------------------------------------- 2. HIBERNATE / ORACLE
hdr "2. HIBERNATE 7 / ORACLE - most explode at STARTUP or RUNTIME"
item "@Where("                              "$(cnt '@Where(' "${J[@]}" "$SRC")"                                                                       "recipe (hand-written): @SQLRestriction"
item "@WhereJoinTable"                      "$(cnt '@WhereJoinTable' "${J[@]}" "$SRC")"                                                               "-> @SQLJoinTableRestriction"
item "@Type / @TypeDef (removed in H6)"     "$(cnt -E '@TypeDef|org\.hibernate\.annotations\.Type\b' "${J[@]}" "$SRC")"                               "MANUAL: @JdbcTypeCode / AttributeConverter"
item "UserType / CompositeUserType impl"    "$(cnt -E 'implements UserType|implements CompositeUserType|extends .*UserType' "${J[@]}" "$SRC")"        "MANUAL: nullSafeGet/Set signatures changed"
item "nativeQuery = true"                   "$(occ 'nativeQuery *= *true' "${J[@]}" "$SRC")"                                                          "CRITICAL: result types java.sql -> java.time"
item "@Temporal"                            "$(occ '@Temporal' "${J[@]}" "$SRC")"                                                                     "java.util.Date mapping behavior changed"
item "trunc( inside @Query"                 "$(occ -E '@Query[^)]*trunc\(' "${J[@]}" "$SRC")"                                                          "DIES AT STARTUP: truncate in Java"
item "nvl/decode/sysdate/rownum in @Query"  "$(occ -E '@Query[^)]*\b(nvl|decode|sysdate|rownum|to_char|to_date|listagg)\b' "${J[@]}" "$SRC")"          "Oracle-specific: coalesce/case"
item "bare @GeneratedValue (=AUTO)"         "$(grep -rho '@GeneratedValue[^A-Za-z]' "${J[@]}" "$SRC" 2>/dev/null | wc -l | tr -d ' ')"                 "Hibernate 6 sequence naming changed"
item "EmptyInterceptor (REMOVED in H6)"     "$(cnt 'EmptyInterceptor' "${J[@]}" "$SRC")"                                                              "MANUAL: implements Interceptor + Serializable->Object id"
item "  ^ interceptor methods w/o @Override" "$(for f in $(grep -rl EmptyInterceptor "${J[@]}" "$SRC" 2>/dev/null); do n=$(grep -cE 'public (boolean|void) (onSave|onFlushDirty|onDelete|onLoad)\(' "$f"); o=$(grep -B1 -E 'public (boolean|void) (onSave|onFlushDirty|onDelete|onLoad)\(' "$f" | grep -c '@Override'); [ "$n" -gt "$o" ] && echo x; done | wc -l | tr -d ' ')" "SILENT RISK: stops overriding, never called"
item "current_session_context_class"        "$(occ 'current_session_context_class' "${R[@]}" "$SRC")"                                                 "dead config -> DELETE"
item "session_factory.interceptor"          "$(occ -A1 'session_factory' "${R[@]}" "$SRC")"                                                           "signature changed"
item "IdentifierGenerator implementation"   "$(cnt 'IdentifierGenerator' "${J[@]}" "$SRC")"                                                            "MANUAL: generate() now returns Object"
item "bare spring-data-jpa (pom)"           "$(grep -c '<artifactId>spring-data-jpa</artifactId>' pom.xml 2>/dev/null)"                      "RUNTIME: switch to starter-data-jpa"
item "bare hibernate-core (pom)"            "$(grep -c '<artifactId>hibernate-core</artifactId>' pom.xml 2>/dev/null)"                       "groupId org.hibernate.orm + starter"
printf '  \033[36mjdbc driver:\033[0m '; grep -hoE '<artifactId>ojdbc[0-9]*</artifactId>' pom.xml 2>/dev/null | tr '\n' ' '; \
  grep -hoE '<groupId>com\.oracle[^<]*</groupId>' pom.xml 2>/dev/null | tr '\n' ' '; echo "  <- decade-old drivers do NOT run on JDK 25 -> current ojdbc11+"

# ---------------------------------------------------------------- 3. WEB / PATH
hdr "3. WEB / PATH - 404 on Boot 4 with a CLEAN compile (contract break!)"
PY=""
for c in python3 python py; do
  if "$c" -c "pass" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -n "$PY" ]; then
  "$PY" - "$SRC" <<'PYEOF'
import re,sys,os
SRC=sys.argv[1] if len(sys.argv)>1 else 'src'
DECL=re.compile(r'\n\s*(?:public\s+|abstract\s+|final\s+)*(?:class|interface)\s+\w+')
CLS =re.compile(r'@RequestMapping\(\s*(?:value\s*=\s*)?\{?\s*"([^"]*)"')
METH=re.compile(r'@(?:Get|Post|Put|Delete|Patch|Request)Mapping\s*\(([^)]*)\)')
def concat(a,b):
    if not a: return b or '/'
    if b=='': return a
    if a.endswith('/') and b.startswith('/'): return a+b[1:]
    if a.endswith('/') or b.startswith('/'): return a+b
    return a+'/'+b
bad=[]; empty=[]; midstar=[]
for root,_,fs in os.walk(SRC):
    if 'target' in root: continue
    for f in fs:
        if not f.endswith('.java'): continue
        p=os.path.join(root,f)
        try: t=open(p,encoding='utf-8',errors='ignore').read()
        except Exception: continue
        if 'Mapping' not in t: continue
        d=DECL.search(t)
        if not d: continue
        head,body=t[:d.start()],t[d.start():]
        cm=CLS.search(head); cls=cm.group(1) if cm else ''
        finals=[]
        for mo in METH.finditer(body):
            args=mo.group(1)
            vals=re.findall(r'"([^"]*)"',args)
            if not vals:
                if re.search(r'\b(path|value)\s*=',args): continue
                vals=['']
            for v in vals:
                finals.append((v,concat(cls,v)))
                if v in ('','/'): empty.append((p,cls,v))
                if re.search(r'\*\*/.+',v): midstar.append((p,v))
        if not finals and cls: finals=[('<none>',cls)]
        for v,fin in finals:
            if fin.endswith('/') and fin!='/': bad.append((p,cls,v,fin))
def show(title,rows,hint):
    n=len(rows)
    col='\033[31m' if n else ''
    print(f"  {col}{n if n else '-':<4}\033[0m {title:<52} {hint if n else ''}")
    for r in rows[:20]:
        print("        "+" | ".join(str(x) for x in r))
show("final pattern ends in '/' -> slashless URL 404s",bad,"BREAKS: DELETE the trailing /")
show("method-level Mapping(\"\") or (\"/\")",empty,"turns 404 once UrlHandlerFilter is added")
show("** mid-pattern (PatternParseException)",midstar,"DIES AT STARTUP")
PYEOF
else
  echo "  (python not found - coarse scan)"
  item "mapping pattern ending in /" "$(occ -E '@(Get|Post|Put|Delete|Patch|Request)Mapping\((value *= *)?"[^\"]*/"' "${J[@]}" "$SRC")" "verify by hand"
fi
item "setUseTrailingSlashMatch/setUseSuffixPatternMatch" "$(cnt -E 'setUseTrailingSlashMatch|setUseSuffixPatternMatch|setUseCaseSensitiveMatch|setUrlPathHelper|setPathMatcher' "${J[@]}" "$SRC")" "REMOVED in SF7 -> does not compile"
item "matching-strategy setting"         "$(occ 'matching-strategy' "${R[@]}" "$SRC")"                                       "ant-path-matcher is NOT a fix; deprecated"
item "addResourceHandler / addPathPatterns" "$(cnt -E 'addResourceHandler|addPathPatterns|excludePathPatterns' "${J[@]}" "$SRC")" "parsed by PathPatternParser now"
item "allowedOrigins(\"*\")"             "$(cnt -E 'allowedOrigins\(\s*"\*"' "${J[@]}" "$SRC")"                              "EXCEPTION with allowCredentials"
item "spring.mvc.servlet.path"           "$(occ 'servlet:' "${R[@]}" "$SRC")"                                                "incompatible with PathPatternParser"
item "catch-all @ExceptionHandler(Exception)" "$(cnt -E '@ExceptionHandler\(\s*(\{\s*)?Exception\.class' "${J[@]}" "$SRC")"   "turns 404 into 500: add NoResourceFoundException handler"

# ---------------------------------------------------------------- 4. JACKSON / JSON
hdr "4. JACKSON / JSON - hits CONSUMERS; tests do not catch it"
item "@JsonInclude"                      "$(cnt '@JsonInclude' "${J[@]}" "$SRC")"                                            "null/absent semantics changed"
item "@JsonFormat"                       "$(cnt '@JsonFormat' "${J[@]}" "$SRC")"                                             "pins date output format (GOOD)"
item "java.util.Date DTO fields"         "$(cnt -E 'private +(java\.util\.)?Date ' "${J[@]}" "$SRC")"                        "format may change WITHOUT @JsonFormat"
item "com.fasterxml ObjectMapper"        "$(cnt 'com.fasterxml.jackson.databind.ObjectMapper' "${J[@]}" "$SRC")"             "RUNTIME: Boot 4 does NOT auto-config this bean"
item "  ^ injected"                      "$(grep -rl 'com.fasterxml.jackson.databind.ObjectMapper' "${J[@]}" "$SRC" 2>/dev/null | xargs -r grep -lE '@Autowired|final ObjectMapper|ObjectMapper [a-z]+\)' 2>/dev/null | wc -l | tr -d ' ')" "needs an ObjectMapper bean from your shared lib"
item "JsonProcessingException catch"     "$(occ -E 'JsonProcessingException|JsonMappingException|JsonParseException' "${J[@]}" "$SRC")" "becomes unchecked on Jackson 3"
item "jackson-* version pins in pom"     "$(grep -B2 -A2 'jackson' pom.xml 2>/dev/null | grep -c '<version>')"     "BANNED: leave to the BOM (cascade failure)"
item "spring.jackson.* settings"         "$(occ 'jackson' "${R[@]}" "$SRC")"                                                 "key names changed in Boot 4"
item "@Builder without @NoArgsConstructor" "$(grep -rl '@Builder' "${J[@]}" "$SRC/main" 2>/dev/null | xargs -r grep -LE '@NoArgsConstructor|^public record| record ' 2>/dev/null | wc -l | tr -d ' ')" "CANNOT deserialize under EXPLICIT_ONLY - fix @RequestBody-path ones"

# ---------------------------------------------------------------- 5. CONFIG / RUNTIME
hdr "5. CONFIG & RUNTIME - the SILENT failure class"
item "server.error.* (now spring.web.error.*)" "$(occ -E '^\s*(include-stacktrace|include-message|include-exception|include-binding-errors|whitelabel)' "${R[@]}" "$SRC")" "recipe: SpringBootProperties_4_0"
item "server.servlet.encoding.*"         "$(occ 'encoding:' "${R[@]}" "$SRC")"                                               "now spring.servlet.encoding.*"
item "management.endpoint.*.enabled"     "$(occ -E 'endpoint:' "${R[@]}" "$SRC")"                                             "-> .access (security!)"
item "bootstrap.yml / bootstrap.properties" "$(ls "$SRC"/main/resources/bootstrap* 2>/dev/null | wc -l | tr -d ' ')"          "NOT read in Boot 4 -> spring.config.import"
item "allow-bean-definition-overriding" "$(occ 'allow-bean-definition-overriding' "${R[@]}" "$SRC")"                          "if still needed, the real problem is elsewhere"
item "logback.xml (NOT logback-spring.xml)" "$(ls "$SRC"/main/resources/logback.xml 2>/dev/null | wc -l | tr -d ' ')"         "<springProfile> DOES NOT WORK here -> rename"
item "janino <if> inside logback"       "$(occ '<if ' --include=logback*.xml "$SRC")"                                         "Logback 1.5: appender NOT attached, NO logs"
item "@ConditionalOnClass(name=\"...\")" "$(cnt -E '@ConditionalOn(Class|MissingClass)\(\s*name' "${J[@]}" "$SRC")"           "string FQCN goes stale silently -> always false"
item "@ConfigurationProperties(\"\")"    "$(cnt -E '@ConfigurationProperties\(\s*(value\s*=\s*)?""' "${J[@]}" "$SRC")"        "configuration-processor NPE"

# ---------------------------------------------------------------- 6. BUILD
hdr "6. BUILD / JDK 25"
item "annotationProcessorPaths MISSING" "$(grep -c 'annotationProcessorPaths' pom.xml 2>/dev/null | awk '{print ($1==0)?1:0}')" "MANDATORY: Lombok does not run at all"
item "uses mapstruct"                   "$(grep -c 'mapstruct' pom.xml 2>/dev/null)"                                "processor + lombok-binding REQUIRED"
item "jacoco < 0.8.14"                  "$(grep -A3 'jacoco-maven-plugin' pom.xml 2>/dev/null | grep -cE '<version>0\.8\.([0-9]|1[0-3])<')" "cannot read class file 69"
item "surefire 2.x pin"                 "$(grep -A3 'maven-surefire-plugin' pom.xml 2>/dev/null | grep -c '<version>2\.')"  "JUnit 6 tests SILENTLY do not run"
item "spring-boot-starter-aop"          "$(grep -c 'spring-boot-starter-aop' pom.xml 2>/dev/null)"                  "GONE in Boot 4 -> starter-aspectj"
item "sleuth / brave"                   "$(grep -cE 'sleuth|io.zipkin.brave' pom.xml 2>/dev/null)"                   "-> micrometer-tracing-bridge-brave"
item "mockito-inline"                   "$(grep -c 'mockito-inline' pom.xml 2>/dev/null)"                           "ended at 5.2"
item "springdoc-openapi-ui (1.x)"       "$(grep -c 'springdoc-openapi-ui' pom.xml 2>/dev/null)"                      "-> starter-webmvc-ui 3.1.x"
printf '  \033[36mparent:\033[0m '; grep -A3 'spring-boot-starter-parent' pom.xml 2>/dev/null | grep -oE '<version>[^<]*' | head -1
printf '  \033[36mjava:\033[0m   '; grep -oE '<java.version>[^<]*' pom.xml 2>/dev/null | head -1
printf '  \033[36mJenkinsfile:\033[0m '; grep -oE 'varJavaHome *= *"[^"]*"' Jenkinsfile 2>/dev/null | head -1

# ---------------------------------------------------------------- 7. DEPLOY / IMAGE / CI
hdr "7. DEPLOY / IMAGE / CI - breakages that live OUTSIDE src/"
EX=""
for p in Dockerfile Dockerfile.jvm Jenkinsfile openshift k8s kubernetes .s2i deploy deployment .mvn .github; do
  [ -e "$p" ] && EX="$EX $p"
done
if [ -n "$EX" ]; then
  item "jarmode=layertools (GONE in 4.1)"        "$(occ -l 'layertools' $EX)"                                  "-> -Djarmode=tools extract --layers"
  item "boot.loader.JarLauncher (class moved)"   "$(occ -l 'JarLauncher' $EX)"                                 "-> java -jar application.jar"
  item "loaderImplementation (CLASSIC gone)"     "$(occ -l 'loaderImplementation' $EX pom.xml)"                 "DELETE"
  item "-Djava.security.manager"                 "$(occ -l 'java.security.manager' $EX)"                        "JVM DOES NOT START (JEP 486)"
  item "UseBiasedLocking / removed GC flags"     "$(occ -lE 'UseBiasedLocking|UseConcMarkSweepGC|UseParNewGC' $EX)" "JVM DOES NOT START"
  item "JAVA_OPTS= (should be JAVA_OPTS_APPEND)" "$(occ -l 'JAVA_OPTS=' $EX)"                                   "wipes memory tuning on RedHat images"
  item "management.health.probes.enabled"        "$(occ -l 'health.probes.enabled' $EX)"                        "renamed -> endpoint.health.probes.enabled"
  item "old java version (image/JAVA_HOME)"      "$(occ -lE 'java1[0-9]|jdk-?1[0-9]|openjdk:1[0-9]|java2[0-4]' $EX)" "should be 25"
  # the next two use INVERTED logic: 0 means MISSING
  tz=$(occ -lE 'TZ=|user[.]timezone' $EX); [ "${tz//[^0-9]/}" = "0" ] &&     printf '  \033[31m%-4s\033[0m %-52s %s\n' "!" "TZ / user.timezone NOT PINNED" "NORMALIZE REQUIRES it -> pin your zone" && FINDINGS=$((FINDINGS+1))
  : > "$TMPM"
  tg=$(occ -l 'terminationGracePeriodSeconds' $EX); [ "${tg//[^0-9]/}" = "0" ] &&     printf '  \033[31m%-4s\033[0m %-52s %s\n' "!" "terminationGracePeriodSeconds MISSING" "graceful shutdown locks rollouts" && FINDINGS=$((FINDINGS+1))
  : > "$TMPM"
else
  echo "  (no Dockerfile/deployment/Jenkinsfile found - deploy files in another repo?)"
fi

hdr "NEXT STEPS"
cat <<'TXT'
  1) Every yellow/red line above is a work item.
  2) Phase 2-a: copy rewrite.yml and RUN it (the single command in SKILL.md).
  3) Re-run this script AFTER the recipe: what remains is manual work.
  4) For every error, search SKILL.md > "Known errors" FIRST. Do not research.
TXT

printf "\n\033[1mFLAGGED ITEMS: %s\033[0m  (non-zero means work; -v shows file:line)\n" "$FINDINGS"
[ "$FINDINGS" -gt 0 ] && exit 1
exit 0
