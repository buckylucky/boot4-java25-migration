---
name: boot4-migration
description: Migrates a Spring Boot 2.6 + Java 17 microservice to Spring Boot 4.1 + Java 25 end to end (inventory, release freeze, transformation, compile-and-fix loop, JDK 25 verification, delivery). Ships with an OpenRewrite composite recipe (rewrite.yml) for the deterministic part, an inventory scanner (scan.sh), and a catalog of 145+ known errors with solutions. Use when asked to migrate/upgrade a service to Boot 4 / Java 25.
---

# Spring Boot 4.1 / Java 25 migration runbook

Target stack: Boot **4.1.x** + Java **25** + Spring Cloud **2025.1.x** (Oakwood), plus the Boot 4 line of your shared platform library (referred to as **`core-util`** throughout; the old library line stays frozen for Boot 2 services).

Sources: (1) a real 8-repo pilot plus staging-environment field cases from an 85-service fleet migration (~3,200 tests green in the pilot wave), (2) measurements across the whole fleet (85 repos / ~41,000 Java files; see "Measured fleet inventory"), (3) the OpenRewrite recipe jars read directly rather than guessed at, (4) an end-to-end dryRun validation of `rewrite.yml` on a real service. This file plus `rewrite.yml` plus `scan.sh` is self-sufficient; you do not need prior knowledge of how the migration works.

## Execution mode (minimum tokens, maximum determinism)

An agent or engineer running this runbook does not invent; it applies:

1. **Prerequisites (once):** JDK 25 installed (Temurin recommended; both `java -version` and `mvn -v` must show 25 for the verification phase). Maven **>= 3.9.0**. IntelliJ >= 2025.2 if used (2024.x does not recognize Java 25 and reports "JDK 0"). The Boot 4 release of `core-util` must resolve from your artifact repository.
2. **Artifact repository precondition — solve this BEFORE the migration, or the recipe will not run at all.** Boot 4.1 artifacts and the OpenRewrite recipe jars are not in your local `.m2`; they download on first run. Two lessons from running behind a corporate Artifactory:
   - **`LATEST` does not resolve through a virtual repository** (`:jar:LATEST (absent)`). Pin versions explicitly; this is also mandatory so that every service produces identical output.
   - The recipe artifacts pull far more transitives than you list (`rewrite-kotlin`, `rewrite-properties`, `rewrite-xml`, `rewrite-json`, `rewrite-java-8/11/17/21/25`, `rewrite-java-lombok`, and more). You do not need to list them, but **your proxy must mirror the whole `org.openrewrite` and `org.openrewrite.recipe` groups.**
   Escape hatches: (a) have DevOps proxy the groups; (b) fill `.m2` on a machine with Central access and run `mvn -o` offline; (c) embed the plugin in the pom with `rewrite-recipe-bom` in `dependencyManagement` so one pin aligns all recipe artifacts.
   **Record the versions resolved in your first pilot (`mvn dependency:list`) and hard-code them in the command.** Otherwise different services run different recipe versions and produce different results.
3. Run `bash scan.sh`; its output is your work list. **Skip the exploration tour, don't write your own greps.**
4. Open the Phase 2 branch, run `rewrite.yml` first (Phase 2-a), then apply ONLY the items scan.sh still flags.
5. In the compile-and-fix loop, search EVERY error in "Known errors" first (grouped by phase: COMPILE / STARTUP / RUNTIME / TEST / BUILD). The vast majority are there, with the fix. No research, no guessing; apply the entry.
6. Only if an error is NOT in the catalog: solve it, then record it in TWO places: this file, and `rewrite.yml` when the fix is deterministic. The recipe gets smarter with every service.
7. Phase 4 verification + Phase 5 delivery. **Unit tests are NOT sufficient**: roughly half of the failure classes only appear when the application boots or when a client makes a real call. A smoke test is mandatory.
8. After the migration, share the "CONTRACT BREAKS" section with consumer teams; some changes break your callers, not you.

---

## Phase 0 — Inventory

```bash
cp <toolkit-dir>/scan.sh . && bash scan.sh        # summary work list
bash scan.sh -v                                    # file:line detail per finding
```

`scan.sh` checks **~70 signals in 7 groups**: compile breakers, Hibernate/Oracle, web/path, Jackson/JSON, config/runtime, build/JDK 25, and **deploy/image/CI** (Dockerfile, deployment manifests, Jenkinsfile — breakages that live outside `src/`: `layertools`, `JarLauncher`, `java.security.manager`, `UseBiasedLocking`, `JAVA_OPTS=`, old base images, missing `TZ`, missing `terminationGracePeriodSeconds`).

- A yellow line is a work item. A red line is a definite breakage or a missing mandatory setting.
- The script prints the flagged-item count and exits non-zero when it is not 0, so you can use it as a CI gate.
- Re-run it AFTER the recipe: whatever remains is manual work. **Target: 0 flagged items.**

Measured impact ratios by service type (files touched by the javax rename): thin WS clients ~2%, mid-tier services ~8%, JPA-heavy services ~26%.

### Out-of-repo inventory — Config Server backend

If your Spring Cloud Config Server serves properties from a JDBC backend (or any store outside the repo), `scan.sh` and the recipe cannot reach it. Run this audit per service against the backing table (columns typically: application, profile, label, key, value):

```sql
-- (a) keys renamed or removed in Boot 3/4:
SELECT application, profile, key, value FROM <your_config_table>
WHERE application = '<service-name>' AND (
      key LIKE 'spring.redis.%'                      -- -> spring.data.redis.*
   OR key LIKE 'spring.data.cassandra.%'             -- -> spring.cassandra.*
   OR key LIKE 'spring.elasticsearch.rest.%'         -- -> spring.elasticsearch.*
   OR key LIKE 'management.metrics.export.%'         -- -> management.<product>.metrics.export.*
   OR key = 'server.max-http-header-size'            -- -> server.max-http-request-header-size
   OR key LIKE 'server.error.%'                      -- -> spring.web.error.*
   OR key LIKE 'server.servlet.encoding.%'           -- -> spring.servlet.encoding.*
   OR key LIKE 'spring.jackson.%'                    -- with Jackson 2 wire -> spring.jackson2.* (old names)
   OR key LIKE 'spring.sleuth.%'                     -- removed (micrometer tracing)
   OR key = 'spring.mvc.pathmatch.matching-strategy' -- removed (PathPattern only)
   OR key = 'spring.mvc.throw-exception-if-no-handler-found'); -- removed (always true)
-- (b) URL values ending in / (trailing-slash 404 risk on Boot 4 targets):
SELECT application, profile, key, value FROM <your_config_table>
WHERE application = '<service-name>' AND value LIKE 'http%' AND value LIKE '%/';
```

Policy for (a) = **dual-write**: do NOT update; INSERT an additional row with the new key. The old row serves the Boot 2 line, the new row serves Boot 4 (both generations silently ignore keys they do not know). Delete the old rows only after the last Boot 2 pod retires. For (b): if the value is a base URL and code concatenates `baseUrl + "path"`, the trailing slash may be intentional; read the consuming code before deleting.

Old version-specific Oracle dialect values need no DB action if you adopt the normalizing EnvironmentPostProcessor pattern in your shared library (see Known errors, Oracle dialect). Otherwise plan the DB fallback update.

## Phase 1 — Freeze the stable line (only if not already done)

1. Check the working tree is clean; do not touch the current branch.
2. `git switch -c release/<current-version> origin/<stable-branch>`
3. Remove `-SNAPSHOT` from the pom version, single commit: "Release X: last stable state".
4. Push + PR to the branch your CI publishes releases from.
5. This version is what Boot 2 line services stay pinned to for the duration of the migration.

## Phase 2 — Transformation branch

`git switch -c feature/boot4-java25-upgrade origin/<stable-branch>`

### 2-a. AUTOMATION FIRST: the composite OpenRewrite recipe

Copy `rewrite.yml` to the service repo root and run it **with JDK 17 or 21** (the rewrite plugin itself is not yet reliable on JDK 25; the pom it produces targets 25):

**FORM 1 — embedded in the pom (RECOMMENDED; one version pin, guaranteed alignment).** `rewrite-recipe-bom` aligns all recipe artifacts to mutually compatible versions. Add temporarily, remove when done:

```xml
<build><plugins>
  <plugin>
    <groupId>org.openrewrite.maven</groupId>
    <artifactId>rewrite-maven-plugin</artifactId>
    <version>6.46.1</version>
    <configuration>
      <configLocation>rewrite.yml</configLocation>
      <exportDatatables>true</exportDatatables>
      <activeRecipes>
        <recipe>org.boot4migration.Boot4Java25Upgrade</recipe>
      </activeRecipes>
    </configuration>
    <dependencies>
      <dependency>
        <groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-recipe-bom</artifactId>
        <version>3.31.0</version><type>pom</type><scope>import</scope>
      </dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-spring</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-migrate-java</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-testing-frameworks</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-hibernate</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-java-dependencies</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-static-analysis</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-micrometer</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-apache</artifactId></dependency>
      <dependency><groupId>org.openrewrite.recipe</groupId><artifactId>rewrite-github-actions</artifactId></dependency>
    </dependencies>
  </plugin>
</plugins></build>
```

```bash
MAVEN_OPTS=-Xmx4g mvn rewrite:run -DskipTests        # preview: rewrite:dryRun  (NEVER pass -U!)
```

**FORM 2 — single command (no pom changes).** Pin the versions resolved in your pilot; `LATEST` will not resolve through a corporate proxy:

```bash
MAVEN_OPTS=-Xmx4g mvn org.openrewrite.maven:rewrite-maven-plugin:6.46.1:run \
  -Drewrite.configLocation=rewrite.yml \
  -Drewrite.activeRecipes=org.boot4migration.Boot4Java25Upgrade \
  -Drewrite.recipeArtifactCoordinates=org.openrewrite.recipe:rewrite-spring:6.37.1,org.openrewrite.recipe:rewrite-migrate-java:3.42.1,org.openrewrite.recipe:rewrite-testing-frameworks:3.44.0,org.openrewrite.recipe:rewrite-hibernate:2.25.0,org.openrewrite.recipe:rewrite-java-dependencies:1.60.2,org.openrewrite.recipe:rewrite-static-analysis:2.41.1,org.openrewrite.recipe:rewrite-micrometer:0.30.1,org.openrewrite.recipe:rewrite-apache:2.30.0,org.openrewrite.recipe:rewrite-github-actions:3.29.0 \
  -Drewrite.exportDatatables=true -DskipTests
```

Preview with `:dryRun` instead of `:run` (patch lands in `target/rewrite/rewrite.patch`).

**Three field lessons (all happened in the original migration):**
1. **Never pass `-U`.** If the pom declares external repositories your network cannot reach, `-U` forces metadata refresh from them, resolution degrades, and **type-based Java steps plus version bumps are skipped SILENTLY.** Symptom: BUILD SUCCESS but only 1-2 files changed and the parent stayed on an old version. Measured on a real repo: 2 files changed with `-U`, 23 without.
2. Run the command **from the repo root** or pass an absolute `-Drewrite.configLocation`; run remotely via `-f` and the plugin looks for rewrite.yml in the working directory and dies with "Recipe(s) not found".
3. **Run with JDK 17/21, not 25**: the plugin compiles the project with its ORIGINAL (Boot 2) pom; on JDK 25 the Lombok processor does not run and the recipe drowns in fake "cannot find symbol" errors.

**THE TWO-COMMIT RULE (keeps a 4,000-file mechanical diff reviewable):**
- **Commit 1 = recipe output only.** Write into the commit message: the `rewrite-maven-plugin` version, the resolved recipe artifact versions, and the SHA of `rewrite.yml` (`git hash-object rewrite.yml`, taken before deleting the copy). Add nothing by hand to this commit.
- **Commit 2 = manual fixes.** The reviewer can now separate "what the machine did" from "what a human did", and can regenerate commit 1 from the same inputs if needed.
- **Do not commit the `rewrite.yml` copy or `target/rewrite/` output.** Delete the repo-root copy after the run; the evidence chain lives in the commit MESSAGE (plugin version + recipe versions + rewrite.yml SHA). The source rewrite.yml is versioned in this toolkit repo; the SHA match keeps commit 1 reproducible. Remove the plugin block from the pom too if you used FORM 1.

**Do not drop any of the 9 recipe artifacts from the list.** The chain references all nine; a missing artifact either errors with "recipe not found" or, worse, skips steps silently.

After the main run, run the diagnostic recipe. **Careful:** the upgrade recipe set `<java.version>` to 25, so a second run selects the Java 25 parser and fails under JDK 17 with "has been compiled by a more recent version of the Java Runtime". Either run it with JDK 25, or force the parser back: `-Djava.version=17 -Dmaven.compiler.release=17`.

```bash
mvn org.openrewrite.maven:rewrite-maven-plugin:6.46.1:run \
  -Drewrite.configLocation=rewrite.yml \
  -Drewrite.activeRecipes=org.boot4migration.Boot4Java25Check
```

This reports **type attribution loss**. In files listed by `FindMissingTypes`, the `ChangeType`/`ChangeMethodName` steps may not have run; check those files by hand. The most common cause of type-attribution loss is the pom failing to resolve during the recipe run (shared library not resolving, artifact proxy unreachable). **Build green but 0 files changed = wrong recipe name or unresolvable pom. Never trust silent success; check `git diff --stat`.**

#### WHAT THE RECIPE COVERS (do not redo)

The backbone is OpenRewrite's official `UpgradeSpringBoot_3_5` chain plus Boot 4 steps:

| Area | Coverage |
|---|---|
| javax to jakarta | `JakartaEE10` (servlet/persistence/validation/annotation, correct scope) |
| Tests | JUnit 4 to Jupiter (including reversed message-argument order), Jupiter to **JUnit 6**, Mockito 4 to 5, `@MockBean`/`@SpyBean` to `@MockitoBean`/`@MockitoSpyBean` (+ `answer` to `answers`, attribute removal), `MockReset` move |
| Property files | **~739 key renames** (`SpringBootProperties_2_0` through `_4_1`) applied to application.yml/properties |
| Security | `WebSecurityConfigurerAdapter` to `SecurityFilterChain`, `authorizeRequests` to `authorizeHttpRequests`, `antMatchers` to `requestMatchers`, lambda DSL, `@EnableGlobalMethodSecurity` to `@EnableMethodSecurity`, PasswordEncoders |
| Framework | 6.1 / 6.2 / 7.0 line, `MigrateResponseStatusException`, `UseObjectUtilsIsEmpty` |
| Hibernate | 6.2 to **7.1** (including `Session.save/delete/get/load` renames). **Careful: the Boot 4.1 BOM manages hibernate-core 7.4.x; the recipe chain ends at 7.1, so 7.2-7.4 changes (readOnly + lazy mutation, `Page` + fetch join, `stream()` cursor leak) are MANUAL and recorded in Known errors.** |
| HTTP client | **HC4 to HC5** (`UpgradeApacheHttpClient_5`); you do not do this by hand |
| commons-lang | 2.x to lang3 (`UpgradeApacheCommonsLang_2_3`) |
| Kafka | `send().completable()` removal, `KafkaHeaders.MESSAGE_KEY` to `KEY`, `PARTITION_ID` to `PARTITION`, `KafkaOperations` return type |
| Boot 4 modularization | `MigrateToModularStarters`: 28 `ChangePackage` steps (autoconfigure packages) + usage-based module starters (`webmvc-test`, `restclient`, `jdbc-test`, `data-jpa-test`) + `spring-kafka` to `spring-boot-starter-kafka` |
| Boot 4 hand-added | redis autoconfigure, `actuate.health` to `health.contributor`, embedded Tomcat packages, `@Where` to `@SQLRestriction` |
| pom versions | parent/plugins/deps **4.1.x**, Spring Cloud **2025.1.2**, springdoc **3.1.0**, old Oracle JDBC to modern coordinates, jacoco 0.8.14, surefire 3.5.x, compiler 3.14.2, byte-buddy, ASM 9.8, lombok 1.18.44, guava/modelmapper/poi/logstash |
| pom removals | starter-aop to **starter-aspectj**, configuration-processor, sleuth+brave, mockito-inline, validation-api, axis, commons-lang2, javax-jaxb, old javax JAX-WS runtime, dead logback appenders, devtools, bare spring-data-jpa/jakarta.persistence-api |
| pom additions | micrometer-tracing-bridge-brave, starter-data-jpa, bouncycastle, **annotationProcessorPaths (lombok + mapstruct-processor + lombok-mapstruct-binding)**, `maven.compiler.parameters=true` |
| Java 25 | `<java.version>25`, SecurityManager/AccessController/Policy removal, `Thread.stop`, `finalize`, `URL` ctor, `ZipError`, `Inflater/Deflater.end`, `Process.waitFor(Duration)` |
| Code | commons-lang to lang3, shaded-jar import accidents (logstash lang3, jersey guava), codehaus Jackson 1.x to fasterxml, POI `getCellTypeEnum`, `javax.ws.rs` exceptions to `ResponseStatusException` (type only) |
| Other | Jenkinsfile JDK path bump, `RemoveRedundantDependencyVersions` (the Jackson pin ban), duplicate dependency/property cleanup |

#### OUTSIDE RECIPE SCOPE (manual work; solutions in Known errors)

Items `scan.sh` still flags after the recipe:

- **Trailing-slash 404s** (see CONTRACT BREAKS): `UrlHandlerFilter` bean + fixing mappings that end in `/`
- Oracle-specific HQL inside `@Query` (trunc/nvl/decode): move the logic to Java
- Native query result types moving from `java.sql` to `java.time`
- `@GeneratedValue` sequence name change (ORA-02289 class of failures)
- `UserType`/`CompositeUserType` implementations: `nullSafeGet/Set` signatures
- `javax.ws.rs` exception constructor arguments (type change is automatic, arguments are not)
- Servlet 6.1 wrapper signatures; `HttpHeaders` no longer a `MultiValueMap`
- `logback.xml` to `logback-spring.xml` + janino `<if>` to `<springProfile>`
- Kafka `ErrorHandler`/`SeekToCurrentErrorHandler` to `CommonErrorHandler`
- Custom `HttpMessageConverter` beans no longer collected automatically
- The Jackson 2 `ObjectMapper` bean (provide it from your shared library)
- Deployment manifests: base image, probe properties, `JAVA_OPTS` cleanup
- Anything living in your Config Server's backend store; the recipe cannot touch it

### 2b. pom.xml — what remains after the recipe

- The recipe hands `<version>` tags to the BOM, but artifacts **removed from Boot 4 dependency management** must KEEP a version; the most common is **`spring-retry`**. If `mvn validate` says "'dependencies.dependency.version' for X is missing", put the version back.
- `spring-boot-starter-web` is kept (deprecated in Boot 4 but working). Moving to `starter-webmvc` is a separate phase; add a single `ChangeDependency` at the end of rewrite.yml if your fleet decides to.
- If any service uses Undertow: **Undertow support was removed entirely in Boot 4.** Move to Tomcat.
- `<optional>true</optional>` dependencies are no longer packaged into the uber-jar. If needed at runtime, drop the optional flag.

### 2c. CI / deployment files

- Point your builder at JDK 25 (the recipe rewrites common Jenkinsfile JDK paths; adapt to your pipeline). Verify the builder actually has JDK 25 the first time.
- Base image to a JDK 25 image.
- `JAVA_OPTS` cleanup is MANDATORY: `-Djava.security.manager=allow` or `-XX:+UseBiasedLocking` means the **JVM does not start at all** (see Known errors / BUILD).
- On Red Hat OpenJDK images, setting `JAVA_OPTS` wipes container memory tuning; use `JAVA_OPTS_APPEND`.
- **PIN THE JVM TIMEZONE. `hibernate.timezone.default_storage: NORMALIZE` makes this MANDATORY.** NORMALIZE reads and writes values using the JVM default zone. During a rolling deploy, Boot 2 and Boot 4 pods write to the same tables; if the new base image comes up in UTC you write **shifted values into the same column, and that is irreversible.** Set it explicitly in BOTH deployment configs: `TZ=<your-zone>` (e.g. `Europe/Istanbul`) or `JAVA_OPTS_APPEND=-Duser.timezone=<your-zone>`. Phase 4 check: log `TimeZone.getDefault()` at startup and compare against a Boot 2 pod; write one row from each generation and compare with `to_char(col,'YYYY-MM-DD HH24:MI:SS')`.
- **Probes:** `management.health.probes.enabled` was RENAMED to `management.endpoint.health.probes.enabled` and now defaults to **true**. So `/actuator/health/readiness`, which returned 404 on Boot 2.6 outside Kubernetes, now returns 200/503. Delete the old key, write the new one explicitly. **Kubernetes trap:** the default `readiness` group contains ONLY `readinessState`; a readinessProbe watching `/actuator/health/readiness` reports healthy **even if your database or Kafka is down**, while one watching `/actuator/health` flaps the pod on any DOWN. Configure deliberately:

  ```yaml
  management.endpoint.health.probes.enabled: true
  management.endpoint.health.group.readiness.include: readinessState,db
  management.endpoint.health.group.liveness.include: livenessState
  ```

  Verify the paths with `curl`, not by assumption.
- **Graceful shutdown is ON by default in Boot 4** (2.6 was `immediate`); see Known errors / RUNTIME "Rollouts hang". Do not ship without `terminationGracePeriodSeconds` and a `preStop` hook, or without explicitly choosing `server.shutdown`.

## Phase 3 — Compile-and-fix loop

If JDK 25 is not yet available locally, catch API breakage early with `mvn compile "-Djava.version=17"` (Boot 4.1 minimum is Java 17), but **compiling on JDK 17 does NOT mean it compiles on JDK 25** (Lombok, byte-buddy, ASM).

Loop: compile, look the FIRST error up in "Known errors", fix, record it if it is new, compile again.
Cascade rule for test failures: a single initialization error (e.g. Jackson) can fail 60+ tests; fix the root cause first, then look at what remains.

## Phase 4 — Final verification on JDK 25

```bash
JAVA_HOME=<jdk-25> mvn clean verify
mvn dependency:tree | grep -iE "javax|sleuth|axis|<old-oracle-jdbc>|hibernate-jpamodelgen"   # should be empty
mvn dependency:tree -Dincludes=net.bytebuddy,org.ow2.asm,org.jacoco                          # verify version floors
bash scan.sh                                                                                 # anything left?
```

**SMOKE TEST — MANDATORY.** The class of failures unit tests cannot catch is large:

1. Boot the application; you must see `Started ...Application in Xs`. For startup failures, see Known errors / STARTUP.
2. `actuator/health` returns **200 and UP** (readiness and liveness separately).
3. The OpenAPI UI loads **and the operation list is populated** (not "No operations defined in spec!").
4. **Call at least one endpoint per controller with the real client format**, especially paths flagged in scan.sh's WEB/PATH section, both with and without a trailing slash. Best automated from a pre-migration call log converted into a collection you can replay.
5. **Diff the JSON output against the Boot 2 output** (date format, null fields, field order). See CONTRACT BREAKS.
6. On a JPA service: run one query per repository (`@Query` methods are validated as beans start), and do one INSERT (the sequence naming change only explodes then).
7. Kafka produce/consume, config server connection, and a traceId visible in logs.
8. Verify the log file actually receives lines (the logback `<if>` trap leaves the app running but LOGLESS).
9. **OpenAPI contract diff**: `curl -s localhost:8080/v3/api-docs | jq -S '.paths|keys'` on both generations and diff. Attach it to the migration PR; include gateway and route owners in the consumer list.
10. **Actuator/observability diff**: capture `health`, `health/readiness`, `health/liveness`, `metrics`, `prometheus`, `conditions`, `configprops`, `env`, `refresh` from both generations and diff. Verify `management.endpoints.web.exposure.include` still lists what your monitoring needs, and that `http_server_requests_seconds_count` exists with `exception="none"` (lowercase).
11. **Jackson wire verification** (if you adopt the "stay on Jackson 2" decision): `curl -s localhost:8080/actuator/configprops | grep -i preferred-json-mapper` must show `jackson2`, and a payload with an unknown field must NOT return 400.

## Phase 5 — Delivery

1. Commit (a message that says what changed and the test result), push, PR into your integration branch, then onward per your branching model.
2. Check nothing you solved is missing from this file.
3. Notify consumer teams of the CONTRACT BREAKS items.
4. Update your project status notes.

---

## Phase 6 — ROLLBACK runbook

Rolling back an image is easy; **data is what you cannot roll back.** Read this before the first pod, and take the countermeasures before the first pod.

**Rollback procedure**
1. Write the image digest of the Phase 1 `release/<version>` into the migration PR description and keep that tag immutable.
2. Rollback = redeploying that digest. **It is only valid while the config store still carries BOTH old and new keys** (see Fleet strategy, dual-write). If you deleted the old keys, the Boot 2 pod boots unconfigured.
3. Before rolling back check: Kafka consumer group offsets, in-flight scheduler entries, open transactions.

**THE IRREVERSIBLES (prevent them; you cannot undo them)**

| What | Why irreversible | Countermeasure (BEFORE the first pod) |
|---|---|---|
| Sequence name / `allocationSize` | generated ids are in the table | `hibernate.id.db_structure_naming_strategy: legacy` (recipe applies) or explicit `@SequenceGenerator` |
| Timezone-shifted timestamps | wrong values written | `TZ=<your-zone>` + `timezone.default_storage: NORMALIZE` (recipe applies) |
| Schema changed by `ddl-auto` | DDL already ran | verify prod uses `validate` or `none` |
| New schema version in a schema registry | stays registered | do not change schemas; verify BACKWARD compatibility mode |
| Serialized cache/session payloads | old generation cannot read them | version-key or flush caches during the window |
| Deleted config keys | Boot 2 pods read them | do not delete until the last Boot 2 pod is gone |

## Fleet-wide invariant check — are all services in the same state?

Every check here is per-repo and human-triggered; with many teams a fleet **silently diverges**. Run an invariant script over all checkouts and print a table:

```bash
printf '%-26s %-9s %-5s %-7s %-6s %-6s\n' SERVICE PARENT JAVA javax apPaths util
for d in */; do s=${d%/}; p=$s/pom.xml; [ -f "$p" ] || continue
  par=$(grep -A3 spring-boot-starter-parent "$p" | grep -oE '<version>[^<]*' | head -1 | cut -c10-)
  jv=$(grep -oE '<java.version>[^<]*' "$p" | head -1 | cut -c15-)
  jx=$(grep -rlE 'import javax\.(servlet|persistence|validation|annotation)' --include=*.java "$s/src" 2>/dev/null | wc -l)
  ap=$(grep -c annotationProcessorPaths "$p")
  mu=$(grep -A2 '<artifactId>core-util</artifactId>' "$p" | grep -oE '<version>[^<]*' | head -1 | cut -c10-)
  printf '%-26s %-9s %-5s %-7s %-6s %-6s\n' "$s" "${par:--}" "${jv:--}" "$jx" "$ap" "${mu:--}"
done
```

Expected: parent `4.1.x`, java `25`, javax `0`, apPaths `1`, same shared-library version everywhere. Every deviating row is a work item. Produce the same table for `sleuth`, `axis`, `hibernate-jpamodelgen`, `spring-boot-starter-aop`, `mockito-inline`.

## Fleet strategy — what order do the services go in?

If most services depend on a shared library, the order is not negotiable:

1. **The shared library (`core-util`) first.** Migrate it, release it, freeze the old line. It is the single home of every solution that would otherwise repeat per service: the `UrlHandlerFilter` bean, the Jackson 2 `ObjectMapper` config, the `NoResourceFoundException` handler, common dependencies (commons-lang3, config client). **Put everything that would be repeated per service in here.**
2. **Version discipline (permanent rule):** ban SNAPSHOT dependencies on your release branch with `maven-enforcer-plugin` `requireReleaseDeps`. When the library needs another API change later, the same discipline applies: validate on a couple of pilots with a SNAPSHOT, cut a release, apply one recipe line to the fleet. Every library API change means recompiling everything that depends on it; freeze the library after the pilots.
3. **Infrastructure services next** (config server, auth server), especially ones that use selective `@Import` instead of package scanning; they need library beans imported by hand.
4. Pilots across service types: one thin WS client (~2% javax impact), one mid-tier service (~8%), one JPA-heavy service (~26%).
5. The rest of the fleet. Services in the same family look alike; after the first three, migrations turn mechanical.

**Freeze the recipe versions.** Note the versions resolved in the first pilot and hard-code them.

**Boot 2 and Boot 4 pods will run SIDE BY SIDE for a while.** During rolling deploys:

- Shared Oracle sequences: Boot 4 defaults to `<entity>_seq`, Boot 2 used `hibernate_sequence`; two lines drawing ids from different sequences. Pin entities to the SAME sequence (legacy naming strategy or explicit `@SequenceGenerator`) before the first pod.
- Shared cookies/sessions: `SameSite`/`Secure` defaults changed.
- Kafka: keep Avro schemas unchanged; `KafkaHeaders` constant names changed but the wire header key strings did not. **Careful:** spring-kafka 4 brings kafka-clients 4.x, which **refuses brokers older than 2.1**; verify the broker before the first Boot 4 pod.
- Tracing: Boot 2 emits B3 headers, Boot 4 emits W3C `traceparent`; correlation breaks. Keep B3 on the Boot 4 side until the whole fleet is over: `management.tracing.propagation.type=b3`.
- **Dual-write config keys.** Unknown keys are ignored silently by BOTH generations, so the safe pattern is: write both spellings BEFORE the first Boot 4 pod, delete the old ones AFTER the last Boot 2 pod:

  ```yaml
  server.error.include-message: always            # read by Boot 2.6 pods
  spring.web.error.include-message: always        # read by Boot 4 pods
  server.servlet.encoding.force-response: true
  spring.servlet.encoding.force-response: true
  management.endpoint.health.enabled: true
  management.endpoint.health.access: unrestricted
  ```

  Do the same for env-var forms in your deployment manifests (`SERVER_ERROR_INCLUDE_MESSAGE` AND `SPRING_WEB_ERROR_INCLUDE_MESSAGE`); in production those are what actually apply. Otherwise, during a rolling deploy, replicas of the SAME service behave differently: some return `message` in error bodies, some do not, and **no log anywhere warns you.**
- Client contract: next section.

---

## CONTRACT BREAKS — these break your CALLERS, not you

None of these show up in compilation or unit tests. Items to notify consumers about in the migration PR:

### 1. URLs ending in `/` now 404

Boot 2.6 (`AntPathMatcher` + `useTrailingSlashMatch=true`) matched both `/x` and `/x/`. Spring Framework 6.0 flipped the default to `false`, and **7.0 removed the option entirely.**

Fleet measurement: 30 controllers had class-level mappings ending in `/`, but **24 of them were fine**, because `PathPattern.combine` does not produce a double slash when joining class and method paths (`@RequestMapping("/api/")` + `@PostMapping("v1/x")` = `/api/v1/x`). The actual breakage was **6 mappings across 4 services** where the FINAL combined pattern ended in `/`.

**Fix — two layers, both required:**

(a) A **`UrlHandlerFilter` bean in the shared library** (Spring Framework 6.2+), so the whole fleet gets it transitively. Use `wrapRequest()`; a redirect leaks internal hostnames behind a route/ingress:

```java
@Bean
FilterRegistrationBean<UrlHandlerFilter> urlHandlerFilterRegistration() {
    UrlHandlerFilter filter = UrlHandlerFilter
            .trailingSlashHandler("/**").wrapRequest()
            .build();
    FilterRegistrationBean<UrlHandlerFilter> reg = new FilterRegistrationBean<>(filter);
    reg.setOrder(Ordered.HIGHEST_PRECEDENCE);   // must run BEFORE Security
    return reg;
}
```

There is no Boot auto-configuration and no `spring.mvc.*` property for this; the bean is required. Filter order: `ForwardedHeaderFilter`, then `UrlHandlerFilter`, then Security, then yours.

(b) **Delete the trailing `/` from the broken mappings.** `UrlHandlerFilter` TRIMS the slash, which means a mapping pattern that itself ends in `/` never matches once the filter is in place; adding the filter alone makes those endpoints entirely unreachable. Both fixes go together.

**Also:** with the filter active, method-level `@GetMapping("")` / `@GetMapping("/")` under a class-level mapping becomes 404 too (pattern is `/base/`, filter makes the request `/base`, no match): remove the method-level path attribute.

**`spring.mvc.pathmatch.matching-strategy=ant-path-matcher` is NOT a fix**: it does not bring trailing-slash matching back and it is deprecated-for-removal in Boot 4.

### 2. 404 bodies turning into 500s

Unmatched URLs (including LB probe hits on `/`) now arrive as `NoResourceFoundException`, which extends `ServletException`, so a generic `@ExceptionHandler(ServletException.class)` swallows it: every probe request logs ERROR + stacktrace AND the consumer sees **500** where it expected 404. Solve it centrally in the shared library's exception advice: a dedicated handler for `NoResourceFoundException` that logs one WARN line (`ex.getHttpMethod()` + `ex.getResourcePath()`, no stacktrace) and returns `HttpStatus.NOT_FOUND`. Spring picks the most specific handler, so generic blocks keep working. **Check every service that catches ServletException or Exception in its own advice.** Diagnostic bonus: if the WARN paths show a real endpoint with a trailing slash, apply the trailing-slash entry above.

### 3. Error body shape — `server.error.*` moved

`server.error.include-stacktrace` is now **`spring.web.error.include-stacktrace`** (55 of our 85 services used the old key). Same for `include-message`, `include-exception`, `include-binding-errors`, `path`, `whitelabel.enabled`. The old key is ignored silently: the `message` field vanishes from error JSON, or stack traces appear unexpectedly. The recipe fixes application.yml; **it cannot fix your config store. Find those rows with the Phase 0 SQL audit and dual-write them.**

### 4. JSON date format

Serialization of `java.util.Date` and `java.sql.Timestamp` fields depends on Boot defaults, and the defaults changed in Boot 4. **The durable fix for contract-critical fields is pinning with `@JsonFormat`.** See Known errors / RUNTIME, "Oracle date format" and the Jackson entries.

### 5. Character encoding

`server.servlet.encoding.*` moved to **`spring.servlet.encoding.*`**. If the old key is ignored, request/response charsets fall back to defaults. Also JDK 18+ makes `Charset.defaultCharset()` UTF-8 everywhere (JEP 400); code reading single-byte-charset files (e.g. ISO-8859-9) breaks. See Known errors / RUNTIME.

### 6. Actuator endpoint access (SECURITY)

`management.endpoint.<id>.enabled` moved to **`.access`** (`none`/`read-only`/`unrestricted`). The old key is ignored: **an endpoint you think you disabled may be open again.** Also `additional-keys-to-sanitize` was REMOVED, so secrets can leak through `/actuator/env`. Audit the `/actuator` tree after migration.

---

## Strategic decisions (do not change these mid-fleet)

- **Stay on Jackson 2 for the wire format, but do it the right way; there is exactly one.** Boot 4's default JSON engine is **Jackson 3** (`tools.jackson`); the BOM manages both lines. **Common false belief:** defining a `com.fasterxml...ObjectMapper` `@Bean` is NOT enough. Boot 4 auto-configures `tools.jackson.databind.json.JsonMapper` as `@Primary` and the HTTP message converter reads THAT; your ObjectMapper bean only serves injection, it does not drive response JSON. The official way to keep the wire on Jackson 2, **all four steps required**:
  1. Add `org.springframework.boot:spring-boot-jackson2` (versionless). Add it **fleet-wide**, not just to "services that use com.fasterxml": a typical DTO-returning controller touches no Jackson type at all, and conditional adoption leaves the fleet with two different wire formats.
  2. **`spring.http.converters.preferred-json-mapper: jackson2`** — THE key that carries the decision. The dependency alone changes nothing.
  3. Remove `jackson-datatype-jsr310` / `jackson-datatype-jdk8` / `jackson-module-parameter-names` dependencies; left versionless they drag both Jackson generations onto the classpath.
  4. Remove any `<jackson-bom.version>` property; it now pins Jackson 3 and a leftover 2.x value produces a nonexistent coordinate.

  Do NOT use `spring.jackson.use-jackson2-defaults=true` on this path: it configures the Jackson 3 mapper and is meaningless when the wire is Jackson 2 (and it had a FAIL_ON_UNKNOWN_PROPERTIES bug before Boot 4.0.6).

  **Namespace conflict to fix by hand:** the property-rename recipe moves keys like `spring.jackson.serialization.write-dates-as-timestamps` to Jackson-3-specific `spring.jackson.datatype.datetime.*` names. With a Jackson 2 wire those are ignored; Jackson 2 settings must live under **`spring.jackson2.*` with the OLD names**. Audit any service that had `spring.jackson.*` settings.

  **Expiry date:** `spring-boot-jackson2` shipped deprecated in Boot 4.0 and WILL be removed in a later 4.x. This decision is a deferral, not a solution. Schedule the Jackson 3 migration as its own phase and check the module still exists at every Boot minor bump.
- **Never pin any Jackson version by hand**: a downgraded `jackson-annotations` breaks Jackson 3's static init and fails every test that builds a RestTemplate, in a cascade.
- **`UpgradeSpringFramework_7_0` and `UpgradeSpringBoot_4_0` recipes are NOT used**: they contain `UpgradeJackson_2_3`, which converts all `com.fasterxml` to `tools.jackson` (see the "UNUSED RECIPES" block at the top of rewrite.yml).
- **The Jackson 3 migration is its own phase and it is not small**: `ObjectMapper` becomes immutable (config moves to `JsonMapper.builder()`), all Jackson exceptions become unchecked (`catch (IOException)` turns into an unreachable-code compile error), `JsonSerializer` becomes `ValueSerializer`, `@JsonSerialize`/`@JsonDeserialize` move packages while `@JsonProperty` STAYS in `com.fasterxml` (no blanket regex).
- **Keep old starter names** (`spring-boot-starter-web` etc.): deprecated but working; modular starters are a separate phase. The recipe preserves this decision.
- **JSpecify null-safety migration is a separate phase**: it touches `@Nullable` in every file and makes the migration diff unreadable.
- **`UpgradeToJava25` is never used as a whole**: its `MigrateMainMethodToInstanceMain` converts `static main` to an instance method and the Spring Boot launcher stops finding it. The safe subset is listed in rewrite.yml.

---

## Known errors and solutions

> Every new error found in a migration gets appended here. **Search here first.**
> Groups follow the phase where the error APPEARS; start in the group matching what you see.

### ═══ COMPILE ═══

#### `'dependencies.dependency.version' for spring-boot-starter-aop is missing`
`spring-boot-starter-aop` was removed in Boot 4 (not in the BOM). The official replacement is **`spring-boot-starter-aspectj`** (the recipe does this). The same error appears for artifacts dropped from Boot 4 dependency management; the most common is **`spring-retry`**: its version must STAY in the pom.

#### `cannot find symbol: class RefreshScope` after removing sleuth
On Boot 2.6, `spring-cloud-context` (home of `@RefreshScope`) reached the classpath as a transitive of sleuth; removing sleuth loses it. Fix: add `spring-cloud-starter-config` (versionless) to your shared library, so services get it transitively, and remove the explicit declaration from service poms. **Careful:** in a repo that does NOT depend on the shared library, do not remove starter-config (re-add it if the recipe removed it), or the config client and `@RefreshScope` disappear. This happened in the field.

#### Old APIs come back after a merge
Symptom: merging from your integration/develop branch breaks the Boot 4 branch again; the NEW code the merge brings was written against Boot 2 APIs and calls helpers or signatures that no longer exist. Fix: do not revert the code; wire it into the structures the migration established. General rule: **run a full compile + test after every upstream merge**; the errors are almost always repeats of entries already in this catalog.

**REVERSE-DIRECTION VARIANT:** the same breakage happens when a regular feature PR lands on your release branch AFTER the upgrade was merged there (the PR was opened in the Boot 2 era). The confusing symptom: the integration-based conflict branch is GREEN while the release branch fails with identical errors, because the fix commit lives only on the integration line. Fix: open a fix branch from the release branch and cherry-pick the fix commit; in conflicts, keep the release side for files that exist only on integration. Process guard: until the migration wave ends, every feature PR aimed at the release branch must be rebased onto the post-upgrade release branch and compiled first.

#### `cannot find symbol: class CronSequenceGenerator`
Removed in Framework 6. Use `org.springframework.scheduling.support.CronExpression`: `CronExpression.parse(cron).next(LocalDateTime.now())` returns `LocalDateTime` (null when no match); for a `Date`, convert via `Date.from(next.atZone(ZoneId.systemDefault()).toInstant())` with a null guard. Cron format and behavior are unchanged.

#### `EnvironmentPostProcessor` moved: `org.springframework.boot.env` to `org.springframework.boot`
The old package is deprecated-for-removal in Boot 4. The `META-INF/spring.factories` key must use the new FQN too. `DeferredLogFactory` constructor injection still works; the spring.factories mechanism is still valid for EnvironmentPostProcessor registration.

#### In library projects: `package org.springframework.boot.actuate.health does not exist` — fixing the import may NOT be enough
If a `HealthIndicator` class lives in your shared library (e.g. an optional, `@ConditionalOnClass`-guarded Kafka/Redis indicator) and the library pom has no actuator at all, compilation keeps failing after the package fix; the class simply is not on the classpath. Fix: add `spring-boot-starter-actuator` to the library pom with **`<optional>true</optional>`**. ALSO: `@ConditionalOnClass(name = "...")` **string literals** keep pointing at the old package and silently evaluate false forever; update them (no compile error, easy to miss), including `FilteredClassLoader(...)` uses in tests.

#### `Fatal error compiling: ... Error processing configuration meta-data ... NullPointerException`
Boot 4.1's configuration processor NPEs on classes with an empty prefix, `@ConfigurationProperties("")`. Fix: remove `spring-boot-configuration-processor`; the metadata only feeds IDE completion. Do NOT fix the empty prefix during the migration; it changes property keys.

#### `package org.apache.commons.lang does not exist` / shaded lang3 import from inside logstash-encoder
Two hidden-transitive accidents: (1) commons-lang **2.x** arrived transitively from old dependencies; (2) code imported the lang3 copy shaded INSIDE logstash-logback-encoder 6.x (an IDE auto-import accident); encoder 8.x has no shading. The recipe converts both.
Policy: **do not add commons-lang3 to service poms**; carry it compile-scoped in the shared library. Optional cleanup where usage is only empty/blank checks, map to Spring utilities (meaning is INVERTED; convert the `!X` forms first or you produce `!!`): `isEmpty(x)` to `!hasLength(x)`, `isNotEmpty(x)` to `hasLength(x)`, `isBlank(x)` to `!hasText(x)`, `isNotBlank(x)` to `hasText(x)`, `equals(a,b)` to `java.util.Objects.equals(a,b)`. Also scan FIELD references: `StringUtils.EMPTY` and `SPACE` do not exist in Spring's StringUtils.

#### `package org.glassfish.jersey.internal.guava does not exist` (static import of `Preconditions`)
`checkArgument`/`checkNotNull` were static-imported from the guava copy shaded inside Jersey (IDE auto-import accident; Jersey arrived as a transitive of the old javax JAX-WS runtime, which is gone in Boot 4). **The recipe converts to real Guava** (`com.google.common.base.Preconditions`; behavior identical: `checkArgument` throws IllegalArgumentException, `checkNotNull` throws NPE). If the repo has no guava, hand-convert to `java.util.Objects.requireNonNull` plus explicit `if (!cond) throw new IllegalArgumentException(...)`. **Do NOT convert to an in-house Preconditions class that throws its own exception type; that changes the error contract** your exception advice maps to HTTP statuses.

#### The old javax JAX-WS runtime `com.sun.xml.ws:rt` stays in the pom
The jakarta migration brings `jaxws-rt` 4.x, but the javax-era artifact has a DIFFERENT name (`rt`), so `com.sun.xml.ws:rt:2.3.x` used to survive. Symptom: `javax.xml.ws / javax.jws / javax.xml.soap` lines in the Phase 4 dependency:tree grep. The recipe now removes it (`RemoveDependency com.sun.xml.ws:rt`). If the code uses no SOAP stubs, old prebuilt SOAP client jars are dead weight, but leave them alone (minimal diff; unloaded javax-annotated classes are harmless).

#### JAX-RS `@Produces(MediaType.APPLICATION_JSON)` leftovers on Spring MVC controllers
A JAX-RS annotation mistakenly placed on Spring MVC controllers; it was inert on Boot 2 too (Spring ignores it), and after the jakarta rename it fails with `package jakarta.ws.rs does not exist`. Fix: DELETE the `@Produces(...)` lines and the `jakarta.ws.rs.Produces` / `jakarta.ws.rs.core.MediaType` imports (behavior unchanged). Exception: if the JAX-RS constant was used inside a Spring attribute like `@PostMapping(produces = MediaType.APPLICATION_JSON)`, switch to Spring's `org.springframework.http.MediaType.APPLICATION_JSON_VALUE` (the JAX-RS constant is a String; Spring's `APPLICATION_JSON` is an object, so `_VALUE` is required).

#### `cannot find symbol: method isEmpty(java.lang.Object)` — Spring `StringUtils`
`org.springframework.util.StringUtils.isEmpty` was removed in Spring 6; use `!hasLength(x)` / `!hasText(x)`. **False-alarm warning:** most `StringUtils.isEmpty(` calls in a codebase are `org.apache.commons.lang3.StringUtils` and are fine. The real breakage is only in files importing Spring's StringUtils; `scan.sh` makes that distinction.

#### `package org.apache.commons.collections does not exist` (3.x, no "4")
commons-collections **3.x** arrived transitively from old dependencies (often Axis). Usage is almost always `CollectionUtils.isEmpty/isNotEmpty`. Fix: do NOT add a dependency; switch to Spring's `org.springframework.util.CollectionUtils` (`isNotEmpty(x)` becomes `!isEmpty(x)`).

#### `package jakarta.ws.rs does not exist` (JAX-RS exceptions the recipe missed)
The recipe's `ChangeType` rules match the **`javax.ws.rs.*` names**, but the jakarta step also renames `javax.ws.rs` to `jakarta.ws.rs`; any JAX-RS exception NOT explicitly listed in rewrite.yml survives as `jakarta.ws.rs.X` and fails compilation. rewrite.yml lists 11 exception types; if you meet a new one, add it. Manual mapping by HTTP code:

| JAX-RS | ResponseStatusException |
|---|---|
| `BadRequestException(msg)` | `new ResponseStatusException(HttpStatus.BAD_REQUEST, msg)` |
| `NotFoundException(msg)` | `... HttpStatus.NOT_FOUND, msg)` |
| `ForbiddenException(msg)` | `... HttpStatus.FORBIDDEN, msg)` |
| `NotAuthorizedException(msg)` | `... HttpStatus.UNAUTHORIZED, msg)` |
| `InternalServerErrorException(msg)` | `... HttpStatus.INTERNAL_SERVER_ERROR, msg)` |

Convert tests too: `assertThrows(BadRequestException.class, ...)` to `ResponseStatusException.class`, and **`exception.getMessage()` to `exception.getReason()`**; `ResponseStatusException.getMessage()` returns `400 BAD_REQUEST "msg"`, not the raw message.

#### `package javax.ws.rs does not exist` (InternalServerErrorException)
The JAX-RS API arrived transitively from old dependencies. **Do NOT add `jakarta.ws.rs-api`**: the API alone is not enough; constructing the exception with a message looks up a `RuntimeDelegate` provider and dies at runtime with `ClassNotFoundException: Provider for jakarta.ws.rs.ext.RuntimeDelegate`. Fix: `new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, msg[, cause])`. The recipe converts the TYPE; **you must add the `HttpStatus` constructor argument by hand.** Also scan for fully-qualified `jakarta.ws.rs.X.class` leftovers.

#### `package org.bouncycastle... does not exist`
BouncyCastle used to arrive transitively. The recipe adds `bcprov-jdk18on`. Note `org.bouncycastle.cert.jcajce` / `.operator` live in **bcpkix**, not bcprov (test scope if only tests use it; the recipe adds it that way).

#### Axis 1.4 dependency used only for `TeeOutputStream`
Axis was not used for SOAP, only for its TeeOutputStream. Fix: host a small local TeeOutputStream in your shared library and delete axis from the pom.

#### POI `cannot find symbol: getCellTypeEnum()`
Removed in POI 5; `getCellType()` already returns `CellType`. The recipe does it.

#### Servlet 6.1 — wrapper classes: `does not override abstract method sendRedirect(String,int,boolean)` / `encodeUrl` / `setStatus(int,String)`
In classes implementing `HttpServletResponse` directly: (1) ADD the `sendRedirect(String, int, boolean)` override (delegate); (2) DELETE the lowercase deprecated `encodeUrl`/`encodeRedirectUrl` overrides (removed from the interface; `encodeURL`/`encodeRedirectURL` stay); (3) DELETE the `setStatus(int, String)` override.

#### `HttpStatusCode cannot be converted to HttpStatus` / `cannot find symbol: getStatusCodeValue()`
Spring 6+ client exceptions return `HttpStatusCode`: use `HttpStatus.valueOf(ex.getStatusCode().value())`. `getStatusCodeValue()` was removed: `getStatusCode().value()` or `.is2xxSuccessful()`. Also `ResponseStatusException.getStatus()` / `getRawStatusCode()` were removed: `getStatusCode()`.

#### Spring 7 — `HttpComponentsClientHttpRequestFactory` no longer accepts HttpClient 4
Symptoms: `cannot access org.apache.hc.client5.http.classic.HttpClient`, `CloseableHttpClient cannot be converted`, `cannot find symbol setConnectTimeout(int)`. **The recipe (`UpgradeApacheHttpClient_5`) does most of this.** What remains manual: (1) SSL-bypass/pool setup via `SSLContexts.custom().loadTrustMaterial(null, (c,s)->true)` (`org.apache.hc.core5.ssl`) + `SSLConnectionSocketFactoryBuilder` + `PoolingHttpClientConnectionManagerBuilder` + `HttpClients.custom().setConnectionManager(...)`; (2) `setConnectTimeout/setReadTimeout` now take `Duration`. **Careful:** after the HC5 restructuring the client is built on EVERY path, so fields that used to be read only on the SSL-bypass path get read on every call; tests constructing the class without Spring may NPE, add null guards.

#### Spring 7 — request buffering is gone: `411 Length Required` / interceptors see an empty body
`ClientHttpRequestFactory` no longer buffers. `Content-Length` is not produced (falls back to chunked; some servers answer 411), and interceptors re-reading the body see it empty. Fix: wrap the factory in `BufferingClientHttpRequestFactory`.

#### Spring 7 — `cannot find symbol: getMethodValue()` (HttpRequest)
Removed; `getMethod()` returns `HttpMethod` now: `httpRequest.getMethod().name()`.

#### `MultiValueMap cannot be converted to HttpHeaders` (Spring Framework 7)
`HttpHeaders` no longer implements `MultiValueMap`; `addAll(MultiValueMap)`, `entrySet()`, `keySet()`, `containsKey()` are gone. Fix: `map.forEach((name, values) -> values.forEach(v -> headers.add(name, v)))`.

#### `cannot find symbol: method fromHttpUrl(String)` (UriComponentsBuilder)
Consolidated: `UriComponentsBuilder.fromUriString(url)` (works for absolute URLs too).

#### Missing `HttpStatus` enum constants (`REQUEST_ENTITY_TOO_LARGE`, `MOVED_TEMPORARILY`, `USE_PROXY`...)
Deprecated constants were removed: `PAYLOAD_TOO_LARGE`, `FOUND`, and so on.

#### `handleExceptionInternal` / `handleBindException` no longer override anything
`ResponseEntityExceptionHandler` signatures moved to the `ProblemDetail` base. Drop `@Override` and move to the new signature, or use the ProblemDetail-returning variant.

#### `CommonsMultipartResolver` removed
Servlet 6 handles multipart natively. Delete the bean; `spring.servlet.multipart.*` properties suffice. A custom resolver moves to `StandardServletMultipartResolver`.

#### spring-kafka — `completable()` / `ErrorHandler` / `SeekToCurrentErrorHandler` / `setRetryTemplate`
`KafkaTemplate.send()` has returned `CompletableFuture` since 3.0; delete `.completable()` (recipe does it). The error-handling API changed completely: `ErrorHandler`/`SeekToCurrentErrorHandler` to **`CommonErrorHandler`/`DefaultErrorHandler`**; `setErrorHandler` to `setCommonErrorHandler`; `setRetryTemplate` removed, use `DefaultErrorHandler(BackOff)` or `RetryTopicConfiguration`. `KafkaHeaders.MESSAGE_KEY` to `KEY`, `RECEIVED_MESSAGE_KEY` to `RECEIVED_KEY`, `PARTITION_ID` to `PARTITION` (recipe does these).

#### Spring Integration 6 — SFTP moved from JSch to MINA SSHD: `cannot find symbol: setSessionConfig`
`DefaultSftpSessionFactory` now uses Apache MINA SSHD; JSch-specific setters are gone. Not covered by the recipe. `sshd-core`/`sshd-sftp` arrive transitively, do NOT add them.

| JSch (SI 5) | MINA SSHD (SI 6+) |
|---|---|
| `factory.setSessionConfig(props)` | `factory.setSshClientConfigurer(client -> ...)` |
| `PreferredAuthentications` key | `CoreModuleProperties.PREFERRED_AUTHS.set(client, "publickey,keyboard-interactive,password")` |
| `StrictHostKeyChecking=no` | `factory.setAllowUnknownKeys(true)` (already existed) |
| `setPrivateKey` / host/port/user/password | unchanged |
| `com.jcraft.jsch.JSchException` | `java.io.IOException` / `org.apache.sshd.common.SshException` |

#### `package org.codehaus.jackson.map does not exist`
A Jackson **1.x** leftover (transitive from old Avro): `com.fasterxml.jackson.databind`. The recipe does it.

#### `package com.fasterxml.jackson.annotate does not exist` — an error PRODUCED by a naive recipe
No such package exists. Cause: an early rewrite.yml did Jackson 1-to-2 as one blanket `ChangePackage: org.codehaus.jackson -> com.fasterxml.jackson`. Jackson 1-to-2 is NOT a flat root rename; subpackages were reorganized, most notably `org.codehaus.jackson.annotate` maps to `com.fasterxml.jackson.annotation`. rewrite.yml now carries 17 ordered rules, specific before general, root rule last with `recursive: false`. Correct mapping table:

| Jackson 1 | Jackson 2 |
|---|---|
| `org.codehaus.jackson.annotate` | `com.fasterxml.jackson.annotation` |
| `org.codehaus.jackson.map` | `com.fasterxml.jackson.databind` |
| `org.codehaus.jackson.map.annotate` | `com.fasterxml.jackson.databind.annotation` |
| `org.codehaus.jackson.node` / `.schema` | `...databind.node` / `...databind.jsonschema` |
| `org.codehaus.jackson.type.JavaType` | `com.fasterxml.jackson.databind.JavaType` (not core!) |
| `org.codehaus.jackson.type` (TypeReference) | `com.fasterxml.jackson.core.type` |
| `org.codehaus.jackson.impl` | `com.fasterxml.jackson.core.json` |
| `org.codehaus.jackson.io` / `.util` / `.sym` / `.format` | `com.fasterxml.jackson.core.<same>` |
| `org.codehaus.jackson.JsonNode` | `com.fasterxml.jackson.databind.JsonNode` (not core!) |
| other root classes | `com.fasterxml.jackson.core.<same>` |
| `.xc` / `.mrbean` / `.smile` / `.jaxrs` | `.module.jaxb` / `.module.mrbean` / `.dataformat.smile` / `.jaxrs.json` |

#### Hibernate 7 — `Object cannot be converted to Serializable` (IdentifierGenerator)
`generate()` now returns `Object`. Make the local variable `Object`; the method return type may stay `Serializable` (covariant).

#### Hibernate 7 — `cannot find symbol: class Where`
`@Where(clause = "...")` was removed: **`@SQLRestriction("...")`** (value only, no attribute name). `@WhereJoinTable` becomes `@SQLJoinTableRestriction`. There is NO OSS OpenRewrite recipe for this; rewrite.yml does it with two hand-written steps (`ChangeType` + `ChangeAnnotationAttributeName clause->value`). Our fleet had 589 occurrences.

#### Hibernate 7 — `Session#load/save/update/saveOrUpdate/delete` removed
`load` to `getReference`, `save` to `persist`, `update`/`saveOrUpdate` to `merge`, `delete` to `remove`. The recipe (`MigrateToHibernate71`) does it.

#### Hibernate 7 — `@Cascade(SAVE_UPDATE)`: "an enum annotation value must be an enum constant" + ALL Lombok output fails in a cascade
A two-layer trap:
1. The visible error is odd: the entity's `@Cascade({CascadeType.SAVE_UPDATE})` line errors with "an enum annotation value must be an enum constant". Hibernate 7 DELETED the SAVE_UPDATE and REPLICATE constants from `org.hibernate.annotations.CascadeType` (because `Session.saveOrUpdate` is gone); javac reports the unresolvable constant this way.
2. **The real devastation is indirect:** this error kills javac's annotation-processing round, Lombok never runs, and hundreds of unrelated `cannot find symbol: variable log` / missing ctor/getter errors print, which look exactly like "annotationProcessorPaths is missing" (even when the pom is complete). Cascade rule: look at the TOP file in the error list; the Lombok flood is usually the shadow of the single real error there.

FIX: delete the `@Cascade` line and its imports. If the relationship already has JPA `cascade = CascadeType.ALL`, behavior is preserved exactly (ALL covers persist+merge, the old SAVE_UPDATE). If not, add `cascade = {PERSIST, MERGE}`. Leave `@Cascade` with still-valid constants (like LOCK) alone. Scan: `grep -rn "CascadeType.SAVE_UPDATE\|CascadeType.REPLICATE" src/`

#### Hibernate 6/7 — `UserType` / `CompositeUserType` implementations do not compile
`nullSafeGet`/`nullSafeSet` signatures were cleaned of the SPI leak; `sqlTypes()` gave way to `getSqlType()`. In most cases replacing the custom UserType with `@JdbcTypeCode` or an `AttributeConverter` is the shorter path.

#### Hibernate 6 — `cannot find symbol: class EmptyInterceptor` (common in audit/common-field interceptors)
`org.hibernate.EmptyInterceptor` was REMOVED. Interceptors doing audit/common-field filling that `extends EmptyInterceptor` and hook in via `spring.jpa.properties.hibernate.session_factory.interceptor` need three coordinated changes:
1. `implements org.hibernate.Interceptor` (the interface now has default methods; override only what you use).
2. **Signatures changed:** the identifier type went from `java.io.Serializable` to **`Object`**: `onSave(Object entity, Object id, ...)`, same for `onFlushDirty`, `onDelete`, `onLoad`.
3. `preFlush(Iterator)` to `preFlush(Iterator<Object>)`.

**If `@Override` is present you get compile errors, and that is the GOOD case.** Without `@Override` the class silently stops overriding anything, is never called, and rows go out with audit fields unfilled: clean compile, green tests, wrong data. Put `@Override` on every interceptor method so the compiler protects you. Tests break too: `interceptor.onSave(entity, mock(Serializable.class), ...)` must become a concrete value or `mock(Object.class)`.
Preferred permanent alternative: move the logic to JPA `@EntityListeners` / `@PrePersist`/`@PreUpdate`; `session_factory.interceptor` is a Hibernate-specific hook that shifts every major release.

#### `hibernate.current_session_context_class: ...ThreadLocalSessionContext`
Dead configuration from the Hibernate 5 era; under Spring's `JpaTransactionManager` the session is managed by Spring, and Spring 7 removed its session-context bridge. **Delete the property.** First grep for `SessionFactory.getCurrentSession()` callers (they need to move to `EntityManager`); if none exist the removal changes nothing.

#### Spring Data — `PagingAndSortingRepository` no longer carries `save/findById/delete`
CRUD and paging interfaces were split in Spring Data 3: extend `JpaRepository<T,ID>` (or `ListCrudRepository` + `ListPagingAndSortingRepository`).

#### Spring Data Commons 4 — `PropertyPath` / `TypeInformation` / `@PersistenceConstructor` missing
`org.springframework.data.mapping.PropertyPath` moved to `org.springframework.data.core.PropertyPath` (same for `TypeInformation`). `@PersistenceConstructor` was removed: `@PersistenceCreator`.

#### `Specification.where(null)` no longer valid
The "match everything" meaning was removed: `Specification.unrestricted()`.

#### `@Async` methods cannot return `ListenableFuture`
`org.springframework.util.concurrent.ListenableFuture` was removed in Framework 7: `CompletableFuture`. In tests, `KafkaTemplate.send()` mocks must return `CompletableFuture` directly; delete `.completable()` stubs.

#### Boot 4 — `package org.springframework.boot.autoconfigure.<X> does not exist`
The compile-time face of Boot 4 modularization: auto-configuration classes moved into technology modules, some RENAMED. The recipe (`MigrateToModularStarters`) converts 28 packages; the ones it misses are hand-added in rewrite.yml:

| Old | New |
|---|---|
| `...autoconfigure.data.redis.RedisAutoConfiguration` | `...boot.data.redis.autoconfigure.DataRedisAutoConfiguration` |
| `...boot.actuate.health.*` (Status/Health/HealthIndicator) | `...boot.health.contributor.*` |
| `...boot.web.embedded.tomcat.*` | `...boot.tomcat.*` |
| `...boot.web.servlet.server.*` | `...boot.web.server.servlet.*` |
| `...autoconfigure.web.servlet.*` | `...boot.webmvc.autoconfigure.*` |
| `...autoconfigure.orm.jpa.*` | `...boot.hibernate.autoconfigure.*` (some in `jpa.autoconfigure` / `persistence.autoconfigure`) |
| `...autoconfigure.jdbc.*` | `...boot.jdbc.autoconfigure.*` |
| `...autoconfigure.kafka.*` | `...boot.kafka.autoconfigure.*` |
| `...autoconfigure.security.*` | `...boot.security.autoconfigure.*` (oauth2 subpackages NOT one-to-one) |
| `...boot.web.client.*` | `...boot.restclient.*` |
| `...boot.test.autoconfigure.web.servlet.*` | `...boot.webmvc.test.autoconfigure.*` |
| `...boot.test.web.client.*` | `...boot.resttestclient.*` |
| `...actuate.autoconfigure.metrics.*` | `...micrometer.metrics.autoconfigure.*` |

Do not GUESS a renamed class's new home; search the jars. Known recipe mis-mapping: `MultipartAutoConfiguration` and some error classes; a second round of "cannot find symbol" after the recipe usually comes from these.

#### `cannot inherit from sealed interface HealthContributor`
`HealthContributor` is **sealed** in Boot 4 (`permits HealthIndicator, CompositeHealthContributor`). Never implement it directly: use `HealthIndicator` for a single check, `CompositeHealthContributor` (easiest via `CompositeHealthContributor.fromMap(...)`) for a tree. `NamedContributor<C>` is gone; iteration types changed.

#### `method does not override or implement a method from a supertype` — `getHealth(boolean)`
`HealthIndicator.getHealth(boolean)` became **`health(boolean includeDetails)`**, and `health()` is now `@Nullable` (null = contribute nothing), so null-guard your own aggregation code. Logic in overridden `health()` of `AbstractHealthIndicator` subclasses moves to `doHealthCheck(Health.Builder)`. **No OpenRewrite recipe does this**; the package recipes only fix imports, so this error appears AFTER the automation and must be hunted manually.

#### `constructor ContentCachingRequestWrapper ... cannot be applied to given types`
Spring Framework 7 removed the single-argument constructor; `(HttpServletRequest, int contentCacheLimit)` is mandatory. **The sneakier second issue:** the wrapper caches content only WHEN it is read and never causes a read itself; if the request short-circuits (Security 401, 404, a handler without `@RequestBody`) `getContentAsByteArray()` returns EMPTY, and audit/logging filters that rely on it silently record nothing. Correct pattern: wrap in a `OncePerRequestFilter` with a limit and make sure something actually reads the body. Also: it does not cache multipart, and part temp files are deleted before the filter chain unwinds.

#### Shared-library API drift — e.g. `BaseException is abstract; cannot be instantiated`
Not a Boot 4 break but a library version jump: services pinned to an old library line hit the accumulated API changes when they move to the Boot 4 release. Map old constructors to the current concrete subclasses; keep a table of these in your own fork of this file.

#### Shared-library API drift — a class/package does not exist in ANY release of the new line
Symptom: `package <your-lib>.<X> does not exist`, and the package is genuinely absent from every release of the new line while the old pinned jar has it. This may not be a migration problem at all: **the old pin may have been published from a feature branch that was never merged.** Do not guess; verify:

```bash
# 1) compare the two jars (is the package really missing?)
unzip -l ~/.m2/.../<lib>-<OLD>.jar | grep "<package-path>"
unzip -l ~/.m2/.../<lib>-<NEW>.jar | grep "<package-path>"
# 2) find the commit that added the class in the library repo
cd <lib-repo> && git log --all --oneline -S "<ClassName>" -- src/main/java
# 3) which branches contain it; was it merged to a mainline?
git branch -a --contains <sha>
git merge-base --is-ancestor <sha> origin/master && echo master:YES || echo master:NO
# 4) which branch tip published the old version?
git log --all --oneline -S "<OLD-VERSION>" -- pom.xml
```

**Do not patch it on the service side** if the classes are part of a serialization contract (e.g. a shared Redis session model): a local copy forks the type graph, and another service deserializing the same session with the older model silently DROPS the fields on its next write. The fix belongs in the library: merge the stranded commit, cut a patch release.

#### Security 7 — `WebSecurityConfigurerAdapter` gone
**The recipe does this, but on complex real configurations it can be a no-op; VERIFY THE DIFF.** Manually: the class extends nothing; `configure(HttpSecurity)` becomes `@Bean SecurityFilterChain securityFilterChain(HttpSecurity http)` ending in `return http.build()`. Conversions: `authorizeRequests` to `authorizeHttpRequests`, `antMatchers` to `requestMatchers`, `.cors().disable()` to `.cors(AbstractHttpConfigurer::disable)`, `.sessionManagement().sessionCreationPolicy(X).and()` to `.sessionManagement(s -> s.sessionCreationPolicy(X))`. In Security 7 the **lambda DSL is mandatory** (non-lambda overloads were REMOVED).

#### Security 7 — `MvcRequestMatcher` / `AntPathRequestMatcher` gone
Use `PathPatternRequestMatcher.withDefaults().matcher(...)`. **The pattern syntax changed too:** no `**` mid-pattern, trailing slash does not match, `/x/*` is one segment. Security rules now go through the SAME parser as MVC mappings; that is the point of the change. **Write an integration test per security rule after the migration**; a silently opened or closed path is a security incident.

#### Apache CXF (JAX-WS / SOAP service) — `package javax.jws / javax.xml.ws does not exist`, and CXF 3.5 does not run on Boot 4
Work list from a real code-first JAX-WS service migration:
1. **`cxf-spring-boot-starter-jaxws` 3.5.x to 4.2.x.** The version choice is not a guess: 3.x = javax (Boot 2), 4.1.x = the Boot 3 line, and **4.2.x compiles against Spring Framework 7 / Boot 4.1** (verified from the cxf-parent pom). rewrite.yml bumps it automatically.
2. **javax to jakarta, three packages:** `javax.jws.*`, `javax.xml.ws.*`, `javax.xml.bind.*` (JAX-WS annotations + JAXB DTOs). `javax.xml.stream` / `javax.xml.datatype` are part of the JDK; leave them.
3. **JAXB 4 NamespacePrefixMapper moved:** `com.sun.xml.bind.marshaller.NamespacePrefixMapper` to **`org.glassfish.jaxb.runtime.marshaller.NamespacePrefixMapper`**; the marshaller property key `com.sun.xml.bind.namespacePrefixMapper` to **`org.glassfish.jaxb.namespacePrefixMapper`**. Left on the old name it is silently ignored at runtime and your namespace-prefix parity with legacy consumers breaks.
4. CXF `EndpointImpl`/`Bus` API, `endpoint.publish("/X")`, the `/services` servlet path and interceptor API (`AbstractPhaseInterceptor`) are unchanged.
5. SOAP-specific smoke: `/services` lists endpoints, every endpoint serves `?wsdl`, one real POST dispatches. REST smoke tooling cannot generate SOAP bodies; diff WSDLs between generations and fire raw XML.
6. **Legacy response-format parity:** the JAX-WS RI produces an XML declaration + `S:`/`env` envelope prefixes + an empty `Header` + `ns0` body prefix; CXF's default (3.5 and 4.2 alike) is no declaration + `soap:` + no Header + `ns2`. The difference only shows against a legacy baseline and breaks strict client parsers. Fix pattern per endpoint: an out+outFault interceptor writing legacy envelope style, `JAXBDataBinding` with a custom prefix mapper (resolve targetNamespace from the SEI when the impl lacks it), and endpoint property `org.apache.cxf.stax.force-start-document=true` (contextual, so an endpoint property suffices and covers faults). One cosmetic difference remains: woodstox writes the declaration with single quotes; XML parsers do not care.

### ═══ STARTUP ═══

> This group contains errors unit tests DO NOT catch. Smoke testing is mandatory.

#### `required a bean of type '...Repository' that could not be found`
The runtime face of Boot 4 modularization: with bare `spring-data-jpa` + `hibernate-core` in the pom (no starter) the app COMPILES, but the JPA auto-config module jar is absent, so repository beans are never created. Fix: delete the bare trio (`spring-data-jpa`, `hibernate-core`, `jakarta.persistence-api`), add `spring-boot-starter-data-jpa` (recipe does it). **General rule: in Boot 4 a technology's auto-config only arrives with its own starter.** "The class is on the classpath so auto-config will run" is no longer true. Same trap for jdbc, kafka, redis, cache, validation, mail, ldap, quartz, batch, actuator, jackson. **Sometimes the auto-config vanishes with no error at all**; verify expected behavior with a smoke test.

#### `RestTemplateBuilder` bean not found
`spring-boot-starter-webmvc` alone does not bring the RestTemplate/RestClient infrastructure: add `spring-boot-starter-restclient` (the recipe adds it when it sees `org.springframework.web.client.*` usage).

#### `required a bean of type 'com.fasterxml.jackson.databind.ObjectMapper'`
Boot 4 no longer auto-configures the Jackson 2 `ObjectMapper` bean (the default is Jackson 3's mapper, a DIFFERENT type). Appears at startup in every service that injects ObjectMapper. Fix: provide a `@ConditionalOnMissingBean`-guarded ObjectMapper bean from your shared library. **CRITICAL: this bean does NOT fix the wire format**; response JSON still comes from Boot 4's `@Primary` Jackson 3 mapper unless you apply the full "stay on Jackson 2" decision (see Strategic decisions, and RUNTIME entry "`@Bean ObjectMapper` silently ignored").

#### `Parameter 1 of function 'trunc()' has type 'NUMERIC', but argument is ... 'TIMESTAMP'`
Oracle-habit HQL applying `trunc(date)` no longer passes: Hibernate 7 validates `trunc()` as numeric, and **`@Query` methods are validated AT STARTUP** (the repository bean fails while building; unit tests do not catch it). Three-stage trap, final answer at the bottom:
1. `trunc(date)` dies in startup validation.
2. Rewriting to `date_trunc(day, x)` passes validation BUT: (a) its semantic type is `java.lang.Object`, breaking constructor expressions; (b) worse, at RUNTIME OracleDialect does not translate `date_trunc` and emits it verbatim: ORA-00904. So `date_trunc` is unusable on Oracle.
3. **Final fix: take day-truncation out of SQL entirely.** Return the raw date column and do truncation + dedup in Java (`.map(Dto::truncatedToDay).distinct()`); dialect-independent. Move to a native query if row volume is large.

To reproduce type/semantic validation WITHOUT a database: build a SessionFactory with `StandardServiceRegistryBuilder` + `hibernate.dialect=OracleDialect` + `hibernate.boot.allow_jdbc_metadata_access=false`, then `createSelectionQuery(hql)`. This validates SEMANTICS, not the generated SQL's validity in the dialect (the date_trunc lesson). General: `nvl` to `coalesce`, `decode` to `case`.

#### Every `@Query` now compiles at bootstrap
One throwaway EntityManager compiles all `@Query` methods during repository bootstrap: broken HQL that "was never called so never noticed" on Boot 2 now **prevents startup**. Additional breakages: JDBC-style `?` placeholders rejected (use `?1` or named); entity-field vs literal comparisons across converted types throw `SemanticException`; `select`-less ambiguous HQL and update/delete on `@Immutable` rejected; native query + `Pageable` requires `countQuery` and rejects dynamic sort; DTO return types silently become constructor expressions ("Missing constructor for type": constructor parameter types must match the query result types EXACTLY).

#### `spring.jpa.hibernate.naming.physical-strategy` points at a class that no longer exists
`SpringPhysicalNamingStrategy` was removed/moved. Use the Boot 4 default (delete the property) or write the new FQCN. **Deleting this setting can change table/column names**; compare generated SQL with `spring.jpa.show-sql` before deleting.

#### `spring.jpa.properties.hibernate.dialect=...Oracle12cDialect` — class missing
Version-specific Oracle dialects were deleted in Hibernate 6; only `org.hibernate.dialect.OracleDialect` remains (detects the version via JDBC metadata; minimum Oracle 19). Best: do not set a dialect at all. **CRITICAL if you run a Config Server with a DB/vault backend: this property usually lives THERE, not in the repo** — repo greps come back empty and local overrides do not help (remote config wins). Two options: (a) put a normalizing `EnvironmentPostProcessor` in your shared library that rewrites any legacy `Oracle*Dialect` value to `OracleDialect` at boot (lets ONE config row serve both generations; this is what we did); (b) fallback: update the config-store row per environment. Services connecting to Oracle older than 19 need `hibernate-community-dialects` + `OracleLegacyDialect`, or they die on OFFSET-FETCH pagination (ORA-00905/00933).

#### Spring Cloud version alignment — 2025.0.x DOES NOT work with Boot 4.1
**2025.1.x is mandatory.** Also the `spring-cloud-starter-parent` artifact was REMOVED in 2025.1; poms using it as parent stop resolving. The recipe pins `spring-cloud.version` to 2025.1.2 and deliberately OVERRIDES the 2025.0.x value the official chain leaves behind. Do not disable `spring.cloud.compatibility-verifier`.

#### Boot 4.1 — `bootstrap-mode: deferred` now explodes at startup
`spring.data.jpa.repositories.bootstrap-mode=deferred` throws while building the EntityManagerFactory if no `AsyncTaskExecutor` bean exists; `lazy` no longer gets a bootstrap executor either. Appears only on the 4.0-to-4.1 step. Fix: ensure `applicationTaskExecutor` exists (don't register a competing bare `Executor`), or `spring.task.execution.mode: force`, or simplest: `bootstrap-mode: default`. Full-context `@SpringBootTest` catches this; `@DataJpaTest` does not.

#### `spring.cloud` settings in bootstrap.yml — never read
`bootstrap.yml`/`bootstrap.properties` are NOT read in Boot 4. Everything there, including `spring.application.name`, silently disappears. Use `spring.config.import=configserver:`.

#### `No spring.config.import set`
If your shared library carries `spring-cloud-starter-config`, the config client arrives transitively and **refuses to start** without `spring.config.import`. Fix: `spring.config.import: "optional:configserver:<url>"` (the optional prefix matters for local/test profiles). `spring.cloud.config.enabled=false` does not stop the check; the import is what counts.

#### `@Bean` method returning `void` or annotated `@Autowired` — startup rejection
Framework 7 treats these as errors now. Fix the bean method.

#### `NoSuchBeanDefinitionException` for a generic-typed bean
Framework 7 tightened generic type matching. Declare the generic parameter explicitly on the bean definition; stop using raw types.

#### `Could not resolve placeholder ...`
The Framework 6.2 placeholder parser was rewritten; nested defaults containing `:` (e.g. URLs) need escaping. Simplify the expression or extract the default into its own property.

#### `BeanCreationException: Could not generate CGLIB subclass`
Proxy defaults consolidated in 7.0 plus strict JDK 25 module access. `final` classes/methods cannot be proxied; prefer `@Configuration(proxyBeanMethods = false)` and interface-based proxies. If needed: `--add-opens java.base/java.lang=ALL-UNNAMED`.

#### `Ambiguous @ExceptionHandler method mapped for [MaxUploadSizeExceededException]`
`ResponseEntityExceptionHandler` now handles this type itself and collides with your own handler. Remove yours or separate with `@Order`.

#### `PatternParseException: No more pattern data allowed after {*...} or ** pattern element`
`**` is only allowed ONCE and at the END. Patterns like `/**/swagger-ui/**` anywhere (mappings, resource handlers, CORS, Security matchers, interceptors, springdoc paths-to-match) **prevent startup**. Rewrite as single-segment `*` or `{*rest}` + branch in Java.

#### `A command line option has attempted to allow or enable the Security Manager`
A leftover `-Djava.security.manager=allow` in JAVA_OPTS/CI: the **JVM does not start** (JEP 486, JDK 24+). Delete it. Same class: `-XX:+UseBiasedLocking` and removed GC flags.

#### Health group validation kills startup: `Health contributors [kafka, mongo] in group 'readiness' do not exist`
`management.endpoint.health.validate-group-membership` defaults to true and REFUSES to start when a group names a missing indicator. During the wave set it false in the common profile, re-enable per service as group lists get fixed. Also `management.health.mongo.*` became `management.health.mongodb.*`.

### ═══ RUNTIME ═══

#### `NoClassDefFoundError: javax/xml/ws/...` — JDK-8-era libraries expect the javax API from the JDK
Symptom: compile and unit tests green, but at RUNTIME a library throws `NoClassDefFoundError: javax/xml/ws/http/HTTPException` (or another `javax.xml.ws.*`). Cause: libraries from the JDK 8 era (field case: **ews-java-api 2.0**, the Exchange e-mail client) reference `javax.xml.ws.*` without declaring it; it was part of the JDK then (removed in Java 11). On Boot 2 the API happened to ride in on old transitives; the clean Boot 4 tree has none. jakarta jaxws-rt does NOT help (different package). Fix: re-add the javax-namespace API jar at runtime scope, excluding the transitives you do not need:

```xml
<dependency>
  <groupId>javax.xml.ws</groupId><artifactId>jaxws-api</artifactId>
  <version>2.3.1</version><scope>runtime</scope>
  <exclusions>
    <exclusion><groupId>javax.xml.bind</groupId><artifactId>jaxb-api</artifactId></exclusion>
    <exclusion><groupId>javax.xml.soap</groupId><artifactId>javax.xml.soap-api</artifactId></exclusion>
    <exclusion><groupId>javax.annotation</groupId><artifactId>javax.annotation-api</artifactId></exclusion>
  </exclusions>
</dependency>
```

Regression guard: a one-line test doing `Class.forName("javax.xml.ws.http.HTTPException")`. Note the deliberate exception in your Phase 4 javax grep. Unit tests never trigger this class load; if the repo uses an old integration library (EWS, ancient SDKs), exercise that flow in the smoke test.

#### Rollouts hang / 502s — graceful shutdown is now the DEFAULT
Boot 2.6 `server.shutdown=immediate`, Boot 4 **graceful**. Symptom: rollouts that took seconds now stall; pod logs show `Commencing graceful shutdown. Waiting for active requests to complete`. 30 s drain per pod times a fleet = rollout paralysis. Do not inherit the default; **choose explicitly.** First-wave parity: `server.shutdown: immediate`. If you adopt graceful (recommended for client-heavy services): `spring.lifecycle.timeout-per-shutdown-phase: 20s`, deployment `terminationGracePeriodSeconds: 45` and a `preStop` sleep of ~8 s. **The preStop sleep is what actually stops the 502s**: it gives the router time to drop the endpoint before Tomcat closes the acceptor. Smoke: start a 15 s request, delete the pod; the request must return 200.

#### `@Async` methods run on throwaway threads — the `taskExecutor` bean NAME is gone
Boot 3.5 removed the `taskExecutor` bean name (now `applicationTaskExecutor`). Injection by name fails loudly. **The dangerous variant is silent:** with an `AsyncConfigurer` bean present there is NO error and `@Async` falls back to `SimpleAsyncTaskExecutor` (a new thread per call, no pool). Fix: register an alias for the old name via a `BeanFactoryPostProcessor`, or return the right bean from `AsyncConfigurer.getAsyncExecutor()`. Related trap: a custom `Executor` bean NOT named `applicationTaskExecutor` is ignored by MVC async. Pin the now-load-bearing defaults explicitly: `spring.task.execution.pool.*` and **`spring.task.scheduling.pool.size` (default 1: ALL `@Scheduled` methods share one thread; one slow job starves the rest).**

#### `IllegalArgumentException: restricted header name: "Connection"` (in production)
Boot 4 **no longer detects Apache HttpClient 4**: RestTemplate/RestClient silently fall back to the JDK HttpClient, which rejects `Connection`, `Content-Length`, `Host`, `Expect`, `Upgrade` headers. Compiles clean, MockRestServiceServer tests pass, **explodes in production.** Choose the factory explicitly: (1) preferred: add `httpclient5` so `HttpComponentsClientHttpRequestFactory` is selected again (the recipe adds it where HC4 was used); (2) or force `spring.http.clients.imperative.factory: simple`; (3) last resort for one header: `-Djdk.httpclient.allowRestrictedHeaders=connection`. Note `spring.http.client.*` is deprecated in 4.1: **`spring.http.clients.*`**.

#### After HC4-to-HC5, every RestTemplate silently moves to the HC5 pool
Boot 4's client detection order: Apache HttpClient, Jetty, Reactor Netty, JDK, Simple. The moment `httpclient5` hits the classpath, ALL RestTemplate/RestClient instances switch to `HttpComponentsClientHttpRequestFactory`; on Boot 2.6 the default was `SimpleClientHttpRequestFactory`. Different pool limits, keep-alive, retry semantics. **Boot 2.6 also had no timeouts at all** (a hidden infinite-wait bug); set them explicitly fleet-wide: `spring.http.clients.connect-timeout: 5s`, `read-timeout: 30s`. Load-test before shipping; the default pool may be too small.

#### HC4-to-HC5 hidden behavior change: `405 Method Not Allowed`, client sends POST but the backend saw GET
HC4's `DefaultRedirectStrategy` followed redirects only for GET/HEAD; HC5 follows ALL methods and on 301/302 **silently converts POST to GET** (verified in bytecode; 303 also GET; 307/308 preserve the method). Any interposed 302 (gateway, WAF, URL normalization) turns your POST into a GET at the backend; the client exception prints the original method, so the message looks self-contradictory, and the redirect is invisible (below interceptors, unlogged). Fix: install a GET/HEAD-only redirect strategy on your shared HttpClient builder to restore HC4 parity; 3xx responses then surface to the caller. Diagnosis: `logging.level.org.apache.hc.client5.http=DEBUG` shows "Redirect requested". General lesson: HC4-to-HC5 is not a package rename; implicit policy defaults (redirect, retry, keep-alive) change too.

#### Dead OAuth2 client library physically cannot run: `IncompatibleClassChangeError: HttpHeaders does not implement java.util.Map`
The abandoned `spring-security-oauth2` (2.x) calls `HttpHeaders` through the `Map` interface it was compiled against; Spring 7's `HttpHeaders` no longer implements `Map`, so the first token request dies. Compile and unit tests pass; the error appears ONLY at runtime on the first real OAuth2 call. No config or exclusion fixes it; the library must go. Replacement pattern that preserves parity: plain `RestTemplate` + a token interceptor (password/client-credentials grant as your case requires, Basic client auth, token cache with early refresh, single retry on 401), sharing the same HC5 client as business calls.
**Two parity traps we hit while replacing it (both invisible to unit tests):**
1. The old library SKIPPED the Basic Authorization header when clientId was empty; a naive `setBasicAuth(clientId, secret)` throws `Username must not be null` on Spring 7. Port the old guard: only set the header when clientId has text.
2. Building the token RestTemplate with `setMessageConverters(...)` wipes the defaults, and the form-encoded token body then finds no converter (`No HttpMessageConverter for ... application/x-www-form-urlencoded`). Include `AllEncompassingFormHttpMessageConverter`.
Lesson: when replacing a dead library, happy-path parity is not enough; port the old library's GUARDS (when did it skip a header?) and the framework defaults you lose by hand-building components. Add at least one REAL external OAuth2 call to the Phase 4 smoke.

#### 400 body changed — Spring 6.1 took over controller parameter validation
MVC now validates constrained `@RequestParam`/`@PathVariable`/`@RequestHeader` parameters WITHOUT class-level `@Validated` and throws **`HandlerMethodValidationException`** (default 400) instead of `ConstraintViolationException`. Old handlers stop firing; the error body changes silently (and with `@Validated` also present you validate twice). Fix: add a `HandlerMethodValidationException` handler to your shared advice (rebuild the old body from `getAllValidationResults()`), keep the old handler for service-layer validation. Smoke-call every controller once with an invalid param.

#### Response JSON varies by pod — `spring.jackson.find-and-add-modules` is now true
EVERY Jackson module on the classpath gets registered: Hibernate proxy wrappers, ISO dates where epoch millis were expected, surprise fields. No error, just different JSON. Turn it OFF for the wave (`spring.jackson.find-and-add-modules: false`; the recipe adds it) and register wanted modules explicitly. A golden-file test (serialize a DTO on Boot 2, diff on Boot 4) catches this before production.

#### Grafana/alert queries went empty — metric tags changed
`http.server.requests` tag `exception`: `"None"` became **`"none"`**; queries filtering the old casing return zero. `http.client.requests` `clientName` became `client.name` (`client_name` in Prometheus). `WebMvcTagsProvider`/`WebMvcTagsContributor` beans are SILENTLY ignored (URI-tag suppression stops working, cardinality explodes): move to the Observation API (`ObservationFilter` / `ObservationPredicate`). Warn dashboard/alert owners in the migration PR.

#### HikariCP saturating / `Connection is not available` after rollout
Graceful shutdown plus open-in-view holds connections long. Mitigation with teeth in 4.1: `spring.datasource.connection-fetch: lazy` and `spring.jpa.open-in-view: false`. And before the first Boot 4 pod, compute `maximumPoolSize × maxReplicas × 2` against your database session limits; shrink pools or set `maxSurge: 0` during the window.

#### `ORA-02289: sequence does not exist` — on the first INSERT
**The sneakiest break.** Hibernate 6+ changed the default sequence naming for `@GeneratedValue(AUTO/SEQUENCE)` from `hibernate_sequence` to **`<table>_seq`** (the Boot 2 control property was removed in Boot 3). Symptoms: missing-sequence schema validation, inconsistent increment-size validation, or runtime ORA-02289. **Primary fix, one property, fleet-wide (the recipe applies it):**

```yaml
spring.jpa.properties.hibernate.id.db_structure_naming_strategy: legacy
```

Secondary, when per-entity precision is needed: explicit `@SequenceGenerator(name=..., sequenceName="HIBERNATE_SEQUENCE", allocationSize = 1)`. Note `allocationSize` defaults to **50**; setups that behaved like 1 get id jumps and **Boot 2/Boot 4 pods clash on the same table**. Mandatory when both generations write during rolling deploys.

#### Native query results return `java.time.LocalDateTime` instead of `java.sql.Timestamp`
Hibernate 7 changed native-query temporal defaults to `java.time`. Symptoms: ClassCastException on Timestamp casts, projection failures, "Missing constructor". **Fleet-wide escape hatch (the recipe applies it), restores Hibernate 5 behavior:**

```yaml
spring.jpa.properties.hibernate.query.native.prefer_jdbc_datetime_types: true
```

Per-query surgical fix: `nq.addScalar("CREATE_DATE", StandardBasicTypes.TIMESTAMP)`. Note `addScalar` no longer accepts the old `Type` classes; `TimestampType` etc. were REMOVED, use `StandardBasicTypes.*`.

#### HQL `like` on a generic `function(...)` call: SemanticException, operand is `java.lang.Object`
Generic `function('name', ...)` calls carry no return-type metadata in Hibernate 7. Wrap in a cast: `cast(function('translate', lower(x), a, b) as string)`.

#### Single-character VARCHAR columns come back as `Character`, not `String`
With a modern Oracle driver, `VARCHAR2(1)` columns in `Map<String,Object>` native results return `Character`. No compatibility property; fix in code: `Objects.toString(result.get("col"), null)` (safe for Character, String and null).

#### Oracle `NUMBER` results come back as `Integer`/`Long`, not `BigDecimal`
`NUMBER(n,0)` now maps to `Integer`/`Long`, `count()` to `Long`. No compatibility property. Robust form: `((Number) row[0]).longValue()` and `new BigDecimal(((Number) row[1]).toString())`. Expression columns (SUM, arithmetic) may resolve `Float`/`Double`: cast money in SQL (`cast(SUM(AMOUNT) as number(19,4))`) or pin with addScalar.

#### "Oracle dates come out different" — root causes and elimination order
Not one cause; THREE layers. Eliminate in order:
1. **The JDBC driver.** Decade-old `ojdbc6`/`ojdbc8` do not run on JDK 25 (or misbehave subtly on JDBC 4.2/4.3 paths). Move to a current `ojdbc11` (the recipe does), and pair it with the SAME-version NLS jar (`orai18n`) if your schemas use non-ISO-8859-1 single-byte charsets; without it you get `SQLException: Non supported character set`. Do NOT set `oracle.jdbc.mapDateToTimestamp=false`; it drops the time component of Oracle DATE.
2. **The Hibernate type system.** The recipe applies a compatibility block restoring Hibernate 5 semantics, none of which needs DDL or data migration:

```yaml
spring:
  jpa:
    properties:
      hibernate.query.native.prefer_jdbc_datetime_types: true
      hibernate.type.preferred_instant_jdbc_type: TIMESTAMP
      hibernate.timezone.default_storage: NORMALIZE
      hibernate.id.db_structure_naming_strategy: legacy
```

Do NOT reach for `hibernate.jdbc.time_zone`: it looks like a timezone fix but shifts ALL LocalDateTime/Date/Timestamp values.
3. **JSON serialization** (the Jackson entries below).
Verification: fire the SAME request at a Boot 2 and a Boot 4 pod and diff the JSON; log one DB-read date via `toString()`, JSON and SQL `to_char` — the trio shows which layer moved.

#### `Schema-validation: wrong column type encountered` (ddl-auto=validate)
Hibernate 6.2 reverted `timezone.default_storage` to `DEFAULT`, which on Oracle means `TIMESTAMP WITH TIME ZONE` and clashes with existing TIMESTAMP columns; `Instant` fields also moved to `TIMESTAMP_UTC` and silently shift by the JVM offset. The compatibility block above fixes both. `LocalTime`/`java.sql.Time` DDL changed too: prefer per-field `@JdbcTypeCode(SqlTypes.DATE)` over altering columns. To see all mismatches at once, generate the schema to a file with `jakarta.persistence.schema-generation.scripts.*` in a scratch profile.

#### `Unable to resolve name [...Oracle10gDialect] as strategy`
See the STARTUP entry on Oracle dialects; if the value lives in your config store, prefer the normalizing EnvironmentPostProcessor in the shared library so one row serves both generations.

#### `ORA-43853` / `ORA-00600` on Oracle 23c with `@Lob`
`spring.jpa.properties.hibernate.dialect.oracle.value_lob_enabled: false`

#### `ORA-00932: expected TIMESTAMP got BINARY`
A null date parameter bound in a native query with unknown type. Bind with an explicit type: `new TypedParameterValue<>(StandardBasicTypes.TIMESTAMP, (java.util.Date) null)`.

#### `ORA-01000: maximum open cursors exceeded` — hours or days after deploy
`Query#stream()` / `getResultStream()` no longer close themselves. Every stream goes in try-with-resources.

#### `PropertyValueException: Detached entity with generated id '...' has an uninitialized version value 'null'` on save
Pattern: service code sets the id of a NEW entity by hand (a custom id generator that honors preset ids) and the `@Version` field is null. `repository.save()` chooses `persist()` (version null means new), and Hibernate 7's `AbstractEntityPersister.isTransient` treats generated-id-strategy + filled id + null version as a contradiction and throws. Hibernate 5 accepted the same flow. Unit tests with mocked repositories never see it.

**The WRONG fix (tried in staging, failed):** seeding `entity.setVersion(0)` for new records. With a non-null version Spring Data `isNew()` returns false, `save()` takes the MERGE path, and Hibernate 7 throws `StaleObjectStateException: Row was already updated or deleted` for a versioned entity whose row does not exist. The error class changes; the flow stays broken.

**The RIGHT fix (in the shared id generator, fleet-wide; verified against hibernate-core bytecode):** override `allowAssignedIdentifiers()` to return `true` on your custom `IdentifierGenerator`. The generator already honored preset ids; it just never told Hibernate. Mechanism (`SimpleValue.createGenerator`): with `allowAssignedIdentifiers()==true` and no explicit null-value setting, the id's unsaved semantics become UNDEFINED, `isTransient` skips the throw, the null version marks the entity transient, and persist INSERTs like Boot 2 did. On the service side, also guard against a request's null version overwriting a loaded entity's version (`if (dto.getVersion() != null) entity.setVersion(...)`). Scan candidates: `grep -rn "\.setId(" src/main --include=*.java` (entity setId before save, not DTO setId).

#### `jakarta.persistence.NonUniqueResultException`
`getSingleResult()`/`getSingleResultOrNull()` now ALWAYS throw on duplicate rows (Boot 2.6 silently returned the first). Typical source: join-fetch or native queries. Fix the query; if the old behavior is truly needed, `query.setResultListTransformer(ResultListTransformer.uniqueResultTransformer())`.

#### `@Type(type = "...")` / `@TypeDef` do not compile
Removed in Hibernate 6. Most custom types are boolean/enum wrappers and should be `AttributeConverter`s; Hibernate ships ready-made ones: `@Convert(converter = org.hibernate.type.YesNoConverter.class)`, `NumericBooleanConverter`, `TrueFalseConverter`.

#### `@Bean ObjectMapper` silently ignored — response JSON does not change (or changes unexpectedly)
**No symptom at all.** Custom mapper config (modules, inclusion, date format, naming) has zero effect on controller JSON. Root cause: Boot 4 auto-configures Jackson 3's `JsonMapper` as `@Primary`, and the HTTP message converter reads THAT. Your `com.fasterxml` ObjectMapper bean lives beside it and never drives the wire. Decide per fleet which mapper OWNS the wire:
- Jackson 2 owns it: `spring-boot-jackson2` + `spring.http.converters.preferred-json-mapper: jackson2` + settings under `spring.jackson2.*` (old names).
- Jackson 3 owns it: move mapper config to a `JsonMapperBuilderCustomizer`, delete the ObjectMapper bean (or rename it to something like `legacyJackson2ObjectMapper` if in-house code injects it).
Related API notes: custom `HttpMessageConverter` beans are no longer collected; the right APIs are `ServerHttpMessageConvertersCustomizer` / `ClientHttpMessageConvertersCustomizer`. `WebMvcConfigurer#configureMessageConverters` now REPLACES the list (use `extendMessageConverters`). `MappingJackson2HttpMessageConverter`, `Jackson2ObjectMapperBuilder` are deprecated-for-removal.

**Second-layer trap from the field (`Jackson2ObjectMapperBuilder.json()`):** hand-building the ObjectMapper bean with the builder does NOT reproduce Boot's old defaults. The builder only disables two features; `WRITE_DATES_AS_TIMESTAMPS` was disabled by BOOT's auto-config customizer, not the builder. Result: dates serialized as arrays (`[2026,9,14,...]`) instead of ISO strings, and external consumers break, while smoke tests that only assert 200-plus-marker pass. Also, user `@Configuration` classes are evaluated BEFORE auto-config, so `@ConditionalOnMissingBean(ObjectMapper.class)` cannot see Boot's bean and SHADOWS the properly configured one, silently disabling `spring.jackson2.*` keys. Fixes: disable `WRITE_DATES_AS_TIMESTAMPS`/`WRITE_DURATIONS_AS_TIMESTAMPS` explicitly in the bean, and retract the whole config class (`@ConditionalOnMissingClass`) when `spring-boot-jackson2` is present so Boot's mapper wins. Lesson: when re-creating a bean the framework used to auto-configure, never assume "the builder applies the same defaults"; Boot's feature defaults live in the auto-config customizer.

#### UTC suffix in date JSON: `Z` instead of `+00:00`
`java.util.Date`/`Timestamp`/`Calendar` fields now serialize as `"...Z"` (Boot 2.6: `"...+00:00"`). Strict consumer parsers break. On Jackson 3: `spring.jackson.datatype.datetime.write-utc-as-offset=true`. For contract-critical fields the only reliable fix is pinning with `@JsonFormat(shape = STRING, pattern = ..., timezone = ...)`.

#### `spring.jackson.*` keys moved — startup FAILS
`Failed to bind properties under 'spring.jackson.serialization'...`: date and enum features left the SerializationFeature enums for new namespaces (`spring.jackson.datatype.datetime.*`, `spring.jackson.datatype.enum.*`; `read`/`write` under `spring.jackson.json.*`; `parser`/`generator` DELETED; `WRITE_NULL_MAP_VALUES` DELETED, use `default-property-inclusion=non_null`). The recipe renames these in the repo; **your config store is manual.**

#### `NullNode.asText()` returns `""` instead of `"null"` — the core of "null handling changed"
**Silent wrong data.** On Jackson 3, `readTree(json).get("field").asText()` on a JSON null returns an empty string; Boot 2.6 returned the 4-char string `"null"`. Every branch built on `"null".equals(x)` or `x.isEmpty()` flips. Use node-type predicates (unchanged): `path()` + `isMissingNode()` / `isNull()`. Also Jackson 3 accessors now THROW where they returned defaults: `intValue()`/`stringValue()` throw on null nodes (`intValue(0)`, `stringValueOpt()` are the safe families), and `fields()`/`fieldNames()`/`elements()` were REMOVED (`properties()`/`propertyNames()`/`values()`).

#### Jackson 3 default changes — silent behavior differences
| Setting | Boot 2.6 | Boot 4 | Impact |
|---|---|---|---|
| `SORT_PROPERTIES_ALPHABETICALLY` | false | **true** | key order changes in every object; string-comparison tests break en masse |
| `FAIL_ON_NULL_FOR_PRIMITIVES` | false | **true** | JSON null into `int`/`boolean` = **HTTP 400** |
| `FAIL_ON_TRAILING_TOKENS` | false | **true** | concatenated/padded JSON rejected |
| Enum serialization | `name()` | **`toString()`** | wire format changes silently for enums overriding toString |
| `USE_GETTERS_AS_SETTERS` | true | **false** | getter-only `List`/`Map` fields silently stay EMPTY (data loss) |

Field case (`FAIL_ON_NULL_FOR_PRIMITIVES`): DTOs with Lombok `@AllArgsConstructor` failed on absent `int`/`boolean` fields with `MismatchedInputException: Cannot map null into type boolean` (stack signature: `PropertyValueBuffer._findMissing`). If the wire goes back to Jackson 2, this error class vanishes; if you stay on Jackson 3, you need a compatibility customizer (`ConstructorDetector.EXPLICIT_ONLY` + the two fail-on features off).

#### With Jackson 3 wire + EXPLICIT_ONLY: `InvalidDefinitionException: Cannot construct instance (no Creators)`
The cost of the EXPLICIT_ONLY compatibility setting: classes with `@Builder` (or only `@AllArgsConstructor`) and NO `@NoArgsConstructor` cannot be constructed at all; Lombok's `@Builder` produces no no-args ctor and EXPLICIT_ONLY ignores the all-args one. Fix every such class on the DESERIALIZE path (direct `@RequestBody` or nested in one): add `@NoArgsConstructor` + `@AllArgsConstructor`. Scan:
```bash
for f in $(git grep -l "@Builder" -- "src/main/**/*.java"); do
  grep -q "@NoArgsConstructor" "$f" || echo "CANDIDATE: $f"; done
```
Fine print: `record`s are NOT affected (canonical ctor is always a creator); `@Builder.Default` does NOT apply through the no-args ctor (absent fields stay null, same as the Boot 2 wire behavior, so parity holds); response/serialize-only DTOs need no creators, leave them.

#### Spring Kafka 4 — Jackson-based serializer classes renamed
`DefaultKafkaHeaderMapper` to `JsonKafkaHeaderMapper`; the `support.serializer` Json classes too. **Fix fully-qualified class names inside application.yml as well** (`spring.kafka.consumer.value-deserializer` etc.); those fail at runtime with ClassNotFoundException, not at compile time.

#### `NoClassDefFoundError: Could not initialize class tools.jackson...` CASCADE
One Jackson init failure fails every test class that builds a RestTemplate (with a misleading secondary "static mocking already registered" in mockStatic users). Root cause is almost always a hand-pinned Jackson 2 version. Remove all `com.fasterxml.jackson.*` pins; the BOM manages them (the recipe's `RemoveRedundantDependencyVersions` does it).

#### Non-UTF-8 text broke (JEP 400)
Since JDK 18, `Charset.defaultCharset()` is ALWAYS UTF-8; `LANG`/`file.encoding` no longer apply. Code reading single-byte-charset files (e.g. ISO-8859-9), CSVs, mails or legacy sockets produces mojibake or `MalformedInputException`. Pass the charset explicitly everywhere (`new InputStreamReader(in, charset)`, `new String(bytes, cs)`, `Files.newBufferedReader(p, cs)`). Do not rely on `-Dfile.encoding=COMPAT`. Locale-sensitive case conversion needs an explicit locale (the Turkish i/I pair is the classic example: `toUpperCase(Locale.of("tr","TR"))`).

#### Date/time text changed (CLDR)
As the JDK's CLDR version advances, formats change; the most visible is the space before AM/PM becoming U+202F (narrow no-break space). Tests and integrations comparing formatted output as strings break. Pin contract-critical formats with explicit patterns; `-Djava.locale.providers=COMPAT` is gone.

#### Local dev: `PKIX path building failed` — the NEW JDK's truststore lacks your corporate CA
Not a code regression: your old local JDK's `cacerts` had the internal CA chain imported ages ago; a fresh JDK 25 install has a clean truststore. Each developer imports the corporate root/intermediate CA once into the new JDK (`keytool -importcert -cacerts ...`). Pods are unaffected (base image truststores are managed).

#### TLS handshake fails against a legacy endpoint
JDK 25 disabled `TLS_RSA_*` cipher suites by default. Permanent fix is the other side moving to modern suites; the temporary override is a `java.security` properties file removing the entry from `jdk.tls.disabledAlgorithms` (get security approval; do not leave it permanent).

#### `NoSuchMethodError` — Thread/ThreadGroup/JMX methods
Code compiled against JDK 17 running on 25: `Thread.stop/suspend/resume`, `ThreadGroup.stop`, `Runtime.runFinalization`, `Object.finalize`, `Subject.getSubject` are gone. The recipe converts the safe ones. **Compiling on JDK 17 HIDES this; run Phase 4 on JDK 25.**

#### `sun.misc.Unsafe` warning flood / JNI native-access warnings
JDK 24+ warns on every Unsafe memory access (guava, modelmapper, netty, objenesis, byte-buddy). Harmless for now; silence with `--sun-misc-unsafe-memory-access=allow` (never `deny`). JEP 472 native-access warnings (Tomcat, Netty): add `--enable-native-access=ALL-UNNAMED` to `JAVA_OPTS_APPEND`.

#### `Appender named [X] not referenced` + the application produces NO LOG AT ALL
Root cause: a janino `<if condition=...>` block in logback config is not applied by Logback 1.5's model processor; `<root>/<logger>` inside `<then>/<else>` are silently skipped. The app runs, LOGLESS. Fix: convert `<if>` to Boot's `<springProfile>`. **CRITICAL:** `<springProfile>` works ONLY in a file named **`logback-spring.xml`**; plain `logback.xml` is loaded by Logback itself, which does not know Spring extensions: rename the file. Do not try the `<condition>` element form (it kills logging init entirely and Spring-context tests die with "Logging system failed to initialize"). Old substring conditions (`contains("dev")`) become exact profile names in `springProfile`. `scan="true"` does not work from classpath config. Also `logging.file.max-size`/`max-history`/`total-size-cap` were REMOVED in Boot 4.1: define rotation in logback config.

#### `Connection refused: localhost:6379` in a service that does not use Redis (health + rebind)
If `spring-boot-starter-data-redis` arrives transitively from your shared library, Boot's `DataRedisAutoConfiguration` builds a connection factory with DEFAULTS (localhost:6379) and a redis health contributor, even though the service never uses Redis. Boot 2 had the same silent factory; Boot 4's health and rebind paths make it a visible failure. Fix, only in services that truly do not use Redis: `@SpringBootApplication(exclude = {DataRedisAutoConfiguration.class})` (note the NEW package `org.springframework.boot.data.redis.autoconfigure`).

#### Swagger UI loads but `/v3/api-docs` is 500: `NoSuchMethodError: Info.summary()`
Root cause: an OLD `io.swagger.core.v3:swagger-annotations:2.1.x` arriving from a Kafka/Avro serializer chain carries the SAME package as springdoc's 2.2.x; which class loads is jar-order luck, so identical services can differ, and a working one is also luck: fix it anyway. Diagnose: `mvn dependency:tree | grep swagger-annotations` showing `:2.1.x`. Fix: exclude the old artifact (centrally in the shared library; the recipe also installs a service-side exclusion). General rule: NoSuchMethodError/ClassNotFound in a swagger/jackson class + two artifacts carrying one package in the tree = exclude the old one.

#### Swagger UI loads but "No operations defined in spec!"
springdoc misaligned with the Boot minor: 3.0.x is the Boot 4.0 line; on 4.1 the UI loads but generates no operations. Fix: `springdoc-openapi-starter-webmvc-ui` **3.1.x**. Careful: OpenRewrite's `UpgradeSpringDoc_3_0` pins exactly the broken line; rewrite.yml does not use it and applies the 3.1 pin after the chain.

#### Tracing went quiet / no traceId in logs
Sleuth-to-Micrometer property mapping is NOT automatic and moved again in Boot 4: `spring.sleuth.*` to `management.tracing.*`; `management.tracing.enabled` to `management.tracing.export.enabled`; zipkin keys under `management.tracing.export.zipkin.*`. Log correlation needs `%mdc{traceId}` in the pattern. **Do NOT register `ObservedAspect` manually:** Boot 4 auto-registers the `@Observed`/`@Timed`/`@Counted`/`@NewSpan` aspects when (1) `spring-boot-starter-aspectj` is present and (2) `management.observations.annotations.enabled=true`; hand-registered aspect beans cause DOUBLE counting, and without the property the annotations silently emit nothing. Sleuth annotation types moved to `io.micrometer.tracing.annotation.*`. Rolling-deploy warning: Boot 2 emits B3, Boot 4 W3C; keep `management.tracing.propagation.type=b3` until the fleet completes.

#### `IllegalStateException: More than the maximum number of request parameters ... ([1000])`
Tomcat 11 dropped `maxParameterCount` from 10000 to **1000** AND now throws where Tomcat 9 silently TRUNCATED the parameter list (the old behavior was also wrong, just invisible). Restore the limit explicitly (`server.tomcat.max-parameter-count: 10000`, `max-http-form-post-size: 4MB`). The error can fire in a FILTER, so plain `@ControllerAdvice` may not see it. Related new limit: Tomcat 11 `maxPartCount` = 50 (every part counts; 8 files + 60 text fields = 413), configurable via `server.tomcat.max-part-count`. **OOMKilled risk when raising it:** Tomcat's own docs size multipart memory as `maxPartHeaderSize × maxPartCount × maxConnections × 2`; a big raise plus default connections reaches gigabytes of NATIVE memory (invisible in heap dumps). Lower `max-connections` together with any raise. These limits apply BELOW Spring: `MaxUploadSizeExceededException` handlers never see them, so keep Spring's multipart limits STRICTER than Tomcat's.

#### `logback.xml` + structured logging — what actually works
Boot's `logging.structured.format.console=ecs|gelf|logstash` has NO effect while a plain `logback.xml` exists (rename to `logback-spring.xml` first), and it does not fully replace logstash-logback-encoder (custom kv fields, caller info are lost). To keep your own logback config and get Boot's JSON, use `StructuredLogEncoder` inside it. Staying on logstash-logback-encoder 8.x during the wave is safe. Note Boot 4's default log pattern changed (ISO-8601 offset timestamps + an application-name field): update regex-based log parsers.

#### `RequestRejectedException` / 400 from the Security firewall
`StrictHttpFirewall` rejects `//`, encoded `%2F`, `%25`, `;`, backslash and control characters by default. If a gateway calls you that way, loosen firewall rules ONE BY ONE (`setAllowUrlEncodedDoubleSlash(true)`...), never wholesale.

#### Encoded `%2F` in a path variable = 400 (Tomcat 11)
The `ALLOW_ENCODED_SLASH` system property is ignored and there is no `server.tomcat.*` property; a `TomcatConnectorCustomizer` must set `encodedSolidusHandling`. Best fix: change the contract to a query parameter.

#### `Invalid character found in the request target` = 400 (Tomcat 11)
Unencoded `[ ] { } | ^ \ " < >` rejected. `server.tomcat.relaxed-path-chars`/`relaxed-query-chars` can loosen; the right fix is client-side URL encoding.

#### CORS — `allowedOrigins("*")` + `allowCredentials(true)` throws
Use `allowedOriginPatterns("https://*.your-domain")`. Also global CORS default methods are GET/HEAD/POST: list `allowedMethods` explicitly or PUT/PATCH/DELETE preflights fail. Framework 7 no longer rejects preflights lacking CORS config with 403; update tests that relied on that.

#### `server.forward-headers-strategy` ineffective in WAR deployments
Register a `ForwardedHeaderFilter` bean manually (`setDispatcherTypes(REQUEST, ASYNC, ERROR)`). Symptom: springdoc server URLs and redirects show internal hostnames.

#### Oracle lock errors arrive as a different exception
`CannotAcquireLockException` instead of `JpaSystemException` (the exception translator got stricter). Review `catch (JpaSystemException ...)` blocks.

#### Mutating a lazy collection inside `@Transactional(readOnly = true)` now throws
Hibernate 7.3+ rejects mutation in a read-only session. Drop `readOnly` or move the mutation to its own transaction.

#### `Page<T>` with a collection fetch join returns different results
Hibernate 7.4 applies the limit in SQL; paginated fetch-join queries now return different (usually wrong) row counts. Move to `@EntityGraph` or the two-step pattern (page of ids, then details).

#### Repository methods reject null arguments/results
Spring Data 4 is JSpecify `@NullMarked`. `findByX(null)` or methods expected to return null blow up at runtime: use `Optional`, stop passing null.

#### Auto-configuration vanished with no error at all
With a module starter missing, the related auto-config is disabled SILENTLY. String-form `@ConditionalOnClass(name = "...")` conditions silently turn false forever after package moves. Compare `/actuator/conditions` output against Boot 2; it is the fastest diagnosis.

#### Spring Batch metadata no longer written
`@EnableBatchProcessing` semantics changed. In batch services, verify the job repository actually writes.

#### `spring.threads.virtual.enabled=true` silently discards thread pool settings
When enabled, `spring.task.execution.pool.*` / `spring.task.scheduling.pool.*` are ignored and JDBC pinning risks appear. **Do not enable during the migration**; separate work item.

#### Config-refresh rebind resets `@Value` fields inside `@ConfigurationProperties` beans (Spring Cloud 5)
After a bus refresh, a CP bean dies in its init method, and every subsequent health check repeats the same BeanCreationException (a refresh-scope health contributor holds the error): or, the silent variant, a primitive `@Value` field quietly resets to its default. Cause: Spring Cloud 5's rebinder added a reset-to-defaults step that constructs a blank instance and copies EVERY settable property onto the live bean; `@Value` fields are not re-injected afterwards. Fix: remove the setter of any `@Value` field inside a CP bean (`@Setter(AccessLevel.NONE)` with Lombok); without a setter the reset cannot touch it. Scan: `git grep -l "@ConfigurationProperties" src/main | xargs grep -l "@Value("`. Rule: do not put `@Value` in CP beans; if you must, no setter. (A related benign WARN, "Cannot create default instance ... skipping property reset", on framework classes without default constructors, needs no action.)

#### Conditional bean in the library + unconditional consumer = environment-dependent startup death
Field case: the shared library defined `KafkaTemplate` beans conditionally on producer-enable flags, while a library `@Service` injected one REQUIRED via `@RequiredArgsConstructor`. Three-layer trap: (1) **Lombok's `@RequiredArgsConstructor` does not copy a field-level `@Qualifier` onto the constructor parameter**, so injection went by type and could silently pick the WRONG template where one flag was on; (2) in the environment with both flags off, no template exists and the context dies; the pod never turns ready and the deployment times out at its progress deadline, which looks like an infrastructure problem until you read the real `UnsatisfiedDependencyException` in the logs; (3) Boot 2 had a safety net (KafkaAutoConfiguration always made a default template); in Boot 4 kafka auto-config lives in its own module and your dependency chain may not include it. Fix: make the consumer optional (`@Autowired(required=false)` field injection WITH the qualifier, plus null guards). Audit rule: **for every `@ConditionalOnProperty` bean in your library, verify every injector is optional**, and never trust `@RequiredArgsConstructor` + field `@Qualifier`.

### ═══ TEST ═══

#### Boot 4.1 test baseline
JUnit Jupiter **6.x**, Mockito **5.2x**, AssertJ **3.27+**, Hamcrest **3.0**. Do not pin `junit-platform-*` artifacts; 1.x pins are now wrong.

#### JUnit 4 tests SILENTLY not running
Boot 4 starter-test does not bring JUnit 4. Remaining JUnit 4 tests need `junit-vintage-engine` (with hamcrest-core exclusion), otherwise **the build is green and those tests never run.** Permanent fix: finish the JUnit 4-to-5 conversion. Watch the reversed argument order on message asserts: JUnit4 `assertTrue(message, condition)` vs Jupiter `assertTrue(condition, message)`.

#### JUnit 6 removed APIs
`junit-platform-runner`, `junit-platform-jfr`, `MethodOrderer.Alphanumeric`, `@CsvFileSource lineSeparator`, `interceptDynamicTest`; platform internals shifted under custom extensions. The recipe (`JUnit5to6Migration`) does most.

#### Surefire — tests not running or `NoSuchMethodError`
2.22.x does not know JUnit 6 (0 tests, green build). Surefire 3.6.0 dropped the junit4/junit47/testng providers, breaking explicit `<provider>` configs. Surefire pins its own `junit-platform-launcher` which can clash with Platform 6: add `junit-platform-launcher` test-scoped if you see launcher conflicts. **Best: delete the surefire `<version>` tag and let the Boot parent manage it.**

#### `Java 25 (69) is not supported by the current version of Byte Buddy`
Old byte-buddy on the test classpath: Mockito AND the Hibernate bytecode enhancer fail together. byte-buddy >= 1.17.5 (best: no pin at all; the BOM manages 1.18.x). Same class of failure: ASM < 9.8 in Maven plugins ("Unsupported class file major version 69").

#### `Mockito is currently self-attaching...` (JDK 25)
Give Mockito to surefire as a `-javaagent`. **CRITICAL: do not overwrite `argLine`** (JaCoCo lives there); merge with `@{argLine}`:

```xml
<argLine>@{argLine} -javaagent:${org.mockito:mockito-core:jar} -XX:+EnableDynamicAgentLoading</argLine>
```

Done wrong, the fork dies "without properly saying goodbye" or **coverage silently zeroes.**

#### JaCoCo `Unsupported class file major version 69` / coverage 0
JaCoCo >= 0.8.14 (the recipe does it). If Lombok-generated code depresses coverage, add `lombok.addLombokGeneratedAnnotation = true` to lombok.config.

#### `SpringExtension` + `@Mock/@InjectMocks` = null mocks (NPE)
Framework 7 removed spring-test's old Mockito integration (`MockitoTestExecutionListener`); `@Mock` fields under `@ExtendWith(SpringExtension.class)` are no longer initialized. Pure unit tests: `@ExtendWith(MockitoExtension.class)`. Spring-context tests: `@MockitoBean` instead of `@MockBean`. **Careful:** MockitoExtension enables STRICT_STUBS; previously green tests now throw `UnnecessaryStubbingException`. Delete genuinely unnecessary stubs; temporarily `@MockitoSettings(strictness = Strictness.LENIENT)`. Remove `MockitoTestExecutionListener` from custom listener lists.

#### `@SpringBootTest` no longer provides MockMvc / TestRestTemplate
- MockMvc: `@AutoConfigureMockMvc` + `spring-boot-starter-webmvc-test` (the recipe adds by usage)
- TestRestTemplate: `@AutoConfigureTestRestTemplate` + `spring-boot-resttestclient`
- Package move: `...test.autoconfigure.web.servlet.*` to **`...webmvc.test.autoconfigure.*`** (`@WebMvcTest` included); `MockMvc` itself did not move.
- `spring-boot-starter-test-classic` is a temporary bridge; prefer module starters (classic does NOT restore old package names).

#### `@MockitoBean` cannot be declared in a `@Configuration`/`@TestConfiguration` class
Move shared mock configs into the test class or a `@TestBean` factory method.

#### `MockedStatic` / `mockConstruction` leaking
"static mocking is already registered in the current thread": an unclosed MockedStatic breaks subsequent tests. Enforce try-with-resources. Frequently a SECONDARY symptom of another root cause (see the Jackson cascade).

#### `@AutoConfigureTestDatabase` default changed
`replace` went from `ANY` to **`NON_TEST`**: an explicitly defined datasource is no longer replaced and tests hit the real DB. Write `replace = ANY`.

#### H2 `MODE=Oracle` no longer good enough for Hibernate 7
Sequences/CTEs and type mappings diverge. Move JPA tests to Testcontainers with a real database image, or lift them to service-level tests.

#### `EmbeddedKafkaZKBroker` / `EmbeddedKafkaRule` gone
spring-kafka 4 removed ZooKeeper. Use `EmbeddedKafkaKraftBroker`.

#### Testcontainers 2.x artifact names changed
Every module gained a `testcontainers-` prefix and JUnit 4 support ended. Not in the recipe chain; do it manually or run `Testcontainers2Migration` separately.

#### `JacksonTester` is Jackson 3 now
The Jackson 2 variant is `Jackson2Tester` (deprecated-for-removal). If your wire stays Jackson 2, use it in tests.

#### Raw JSON string assertions break
Field order and date rendering changed. Move to order-insensitive comparison (JSONAssert or similar).

#### spring-ldap 4 — `LdapQueryBuilder.is(null)` now throws
The old version tolerated null; 4.x dies while building the query (shows up in mocks as "zero interactions with ldapTemplate"). Stub the value-producing mocks explicitly.

#### `CapturedOutput` / `OutputCaptureExtension` sees no log lines
Usually the "appender not attached" problem; fix that first. Make the test independent of the console anyway: attach a logback `ListAppender` in the test and assert on `getFormattedMessage()`.

#### JDK 25 — exception MESSAGE formats changed; tests asserting on messages break
`StringIndexOutOfBoundsException` says `begin -1, end 4, length 4` on JDK 17 but `Range [-1, 4) out of bounds for length 4` on JDK 25 (other bounds-check exceptions changed similarly). Do not assert on JDK message text: assert the type, or match an invariant fragment (e.g. `contains("-1")`).

#### Mockito — with a parameterized constructor, `@Autowired` FIELD injection does not happen
In mixed-injection classes (final ctor fields + an `@Autowired` field), `@InjectMocks` fills only the constructor; the field stays null. Old tests passed by accident thanks to a DOUBLE init (`MockitoExtension` + a redundant `openMocks(this)` call); removing the redundant call exposes it (double init also sends stubs to the wrong mock set; clean up both). Fix: set the field in the test via `ReflectionTestUtils.setField` (or construct the service by hand).

#### `reference to ResponseEntity is ambiguous` (null body)
Spring 7 added a `ResponseEntity(HttpHeaders, HttpStatusCode)` overload; `new ResponseEntity<>(null, status)` is ambiguous: cast `(Object) null`.

#### Spring 7 — anonymous `HttpRequest` implementations: `does not override abstract method getAttributes()`
Add `getMethod()` (returns HttpMethod) and `getAttributes()` (an empty HashMap suffices) overrides; delete `getMethodValue`.

#### Test contexts are now PAUSED between test classes
Boot 4 context pausing: `Lifecycle` beans stop between classes; embedded Kafka listeners, schedulers, and `@PostConstruct` workers do not behave as before. Make such tests deterministic with `@DirtiesContext` or explicit start/stop. Also `SpringExtension` now uses a test-METHOD-scoped `ExtensionContext`; `@Nested` hierarchies and custom listeners behave differently.

#### `@WebMvcTest` context fails: `NoSuchBeanDefinitionException ... CacheManager ... no CacheResolver specified`
Symptom: the slice's FIRST method fails to load the context; the rest report "ApplicationContext failure threshold (1) exceeded" (wrappers; the real `Caused by` is under the first). Cause: `CacheAspectSupport` now looks the CacheManager up at context refresh (Boot 2 was lazy). If `@EnableCaching` sits on the main `@SpringBootApplication` class, `@WebMvcTest` loads it but `CacheAutoConfiguration` is not part of the slice: no CacheManager, dead context. The app itself boots fine; only slices break. Fix (one file, no prod behavior change): move `@EnableCaching` to a separate `@Configuration` class; slices do not scan those. Detect: `grep -rn "EnableCaching" src/main` pointing at `*Application.java`. The same trap can apply to `@EnableScheduling`/`@EnableAsync`.

#### `Unrecognized field "isXxx"` — Lombok `boolean isXxx` fields
The private field's implicit Jackson name is `isTest`; Lombok's `isTest()`/`setTest()` pair implies `test`. Jackson collects them as two SEPARATE properties, and the invisible field-based one drops, so `@JsonAlias` on the field is INERT. Fix: unify with an explicit name:

```java
@JsonProperty("test")
@JsonAlias("isTest")
private boolean isTest;
```

Detect: `grep -rn "private boolean is[A-Z]" src/main`

#### JAXB marshal silently returns null — `com.sun.xml.bind.*` property aliases removed
Symptom: marshal helpers return null and tests die on the null; the real exception is swallowed by a catch block and only logged. Cause: glassfish `jaxb-runtime` 4.x (from the Boot 4 BOM) removed the old `com.sun.xml.bind.*` property names; `setProperty("com.sun.xml.bind.xmlHeaders", ...)` now throws `PropertyException`. Fix: switch to the `org.glassfish.jaxb.*` equivalents; if `Marshaller.JAXB_FRAGMENT` is already set, an empty `xmlHeaders` is useless, delete the line entirely. Detect: `grep -rn "com\.sun\.xml\.bind\." src/`

### ═══ BUILD / CI ═══

#### JDK 25 mandatory version floors
| Component | Minimum | Note |
|---|---|---|
| Maven | **3.9.0** | 3.6.x is not enough |
| maven-compiler-plugin | **3.14.2** | 3.14.1 and older die on JDK 25 |
| maven-surefire/failsafe | 3.5.x | best left to the parent |
| JaCoCo | **0.8.14** | class file 69 |
| Lombok | 1.18.40 (prefer **1.18.44+**) | phantom `val` errors |
| byte-buddy | **1.17.5** (BOM: 1.18.x) | Mockito + Hibernate enhancer |
| ASM | **9.8** | all ASM-based plugins |
| avro-maven-plugin | 1.12.1 / 1.11.5+ | code-injection CVE |
| MapStruct + processor | same version | 1.6.x |
| Oracle JDBC | current ojdbc11+ | decade-old drivers unsupported on JDK 25 |

#### Mass `cannot find symbol` on Lombok output (log, getters, builders...)
JDK 23+ javac disabled implicit annotation-processor discovery from the classpath: Lombok does not run at all (**the same pom compiles on JDK 17; do not be fooled**). Fix: `annotationProcessorPaths` on maven-compiler-plugin (the recipe adds it). **Careful:** once `annotationProcessorPaths` is set, ONLY listed processors run; MapStruct services need `mapstruct-processor` + `lombok-mapstruct-binding` too, or mapper impls are silently not generated.

#### `parameter name information not found in class file`
Spring Framework 7 requires `-parameters`. The Boot parent enables it, but it can vanish when `annotationProcessorPaths` is added or the parent is absent: pin `maven.compiler.parameters=true` (the recipe adds it). Otherwise `@RequestParam`/`@PathVariable`, constructor-bound `@ConfigurationProperties` and derived queries fail at RUNTIME.

#### CI broke with no code change: `AotProcessingException` / `PersistenceException`
Boot 4.1 runs `process-aot` **even with `-DskipTests`**, and process-aot builds the REAL BeanFactory: the build suddenly needs your database and config server. Fixes: (1) use `-Dmaven.test.skip=true` in CI; or (2) do not bind `process-aot` at all for plain servlet services (no gain, and `@RefreshScope` is unsupported under AOT); or (3) if you want AOT, neutralize the DB at build time via plugin `<jvmArguments>`: `-Dspring.jpa.hibernate.ddl-auto=none -Dspring.jpa.properties.hibernate.boot.allow_jdbc_metadata_access=false -Dspring.cloud.config.enabled=false`.

#### `jarmode=layertools` removed
`java -Djarmode=layertools -jar app.jar extract` breaks in 4.1: use `-Djarmode=tools extract --layers`.

#### `JarLauncher` class moved / `loaderImplementation` CLASSIC gone
Custom ENTRYPOINTs referencing `org.springframework.boot.loader.JarLauncher` break: use `java -jar application.jar`. Delete `<loaderImplementation>CLASSIC</loaderImplementation>`.

#### git-commit-id plugin coordinates changed
`pl.project13.maven:git-commit-id-plugin` became `io.github.git-commit-id:git-commit-id-maven-plugin`. On the old name, `git.properties` is **silently not generated**.

#### Static analysis scanners on JDK 25
sonar-maven-plugin and scanner JREs must support JDK 25; verify on the first service that scanners can read class file 69, or quality gates silently scan incomplete data. Also audit CI stages guarded by `when { branch '<release-branch>' }`: feature builds staying green PROVES NOTHING about those stages; they fail for the first time on the release merge.

#### Sonar quality gate: "Line Coverage on New Code" fails
Every executable line the migration touches counts as "new code", one-line mechanical edits included. Helper methods the migration adds count too. Fix: before pushing, list changed files (`git diff --stat <base>...HEAD -- src/main`) and cover added/changed executable lines; `ReflectionTestUtils.invokeMethod` is legitimate for unreachable private branches. Verify locally in the JaCoCo XML.

#### Sonar quality gate: "New Code Smells" fails (deprecation cascade)
Upgraded libraries deprecate old APIs, and every touched file surfaces those usages as new smells in one burst (a real service: 35 smells, gate down). Two deterministic sources, both fixable with zero behavior change:
- **swagger-annotations 2.2+: `@Schema(required = true)` deprecated**: `@Schema(requiredMode = Schema.RequiredMode.REQUIRED)`. Careful: `parameters.RequestBody(required = true)` is a DIFFERENT attribute and NOT deprecated; leave it.
- **commons-lang3 3.18+: `StringUtils.equals` deprecated**: `java.util.Objects.equals` (behavior identical for Strings, null-safety included).
Pre-push scan: `grep -rn "required = true" src/main | grep Schema` and `grep -rn "StringUtils.equals(" src/main`.

#### Avro-generated models not compiling with the new runtime
`SpecificRecord` classes generated with 1.8 can be incompatible with the 1.11+ runtime: regenerate from the .avsc files.

#### OpenRewrite `Java25Parser ... compiled by a more recent version of the Java Runtime`
Run rewrite-maven-plugin on JDK 17/21. Other frequent failures: `OutOfMemoryError` (set `MAVEN_OPTS=-Xmx4g`); "Failed to parse or resolve the Maven POM" (your shared library is not resolving; **type-based steps get skipped silently** when this happens); "Recipe not found" (incomplete `recipeArtifactCoordinates`).

#### `spring-retry` version missing
Removed from Boot 4 dependency management: the pom must keep an explicit version. `RemoveRedundantDependencyVersions` does not delete unmanaged versions, but do not delete it by hand either.

## Known warnings (non-blocking, leave them)

- `sun.misc.Unsafe` warnings from guava/modelmapper/netty: fixed by future library updates.
- `Appender named [X] not referenced` in TEST JVMs: `springProfile` blocks are ignored in the pre-Boot pure-logback phase; harmless IF the appender is really attached (verify a log line is produced).
- Spring Cloud 5 refresh: `Cannot create default instance of ... for reset; skipping property reset` on framework classes with no default constructor: the reset step is skipped with a WARN, flow continues; no action.
- A local `optional:configserver:http://localhost:...` import producing a "Could not locate PropertySource ... Connection refused" WARN in pods while the real config import comes from deployment env: noise; parameterize the local URL with an env placeholder if it bothers you.
- kafka-clients 4.x: "Not updating high watermark ... as it is no longer assigned" WARNs after rebalance: known noise; verify bus refresh reaches the service once, then ignore.

---

## Measured fleet inventory (reference; from the original 85-service migration)

Numbers below are what the signals looked like across 85 repos / ~41,000 Java files. Run the same measurement on your fleet to size the work:

| Signal | Count |
|---|---|
| Files importing `javax.*` | 4,022 |
| Files using `javax.ws.rs` | 42 |
| `@Where(` | 589 |
| `UserType` implementations | 17 |
| `@Type` / `@TypeDef` | 0 |
| `@Temporal` | 106 |
| Entity fields `java.util.Date` / `java.time` | 196 / 12 |
| `nativeQuery = true` | 47 |
| Bare `@GeneratedValue` (=AUTO) | 29 |
| Decade-old Oracle JDBC poms | 30 |
| `@JsonInclude` / `@JsonFormat` / `ObjectMapper` files | 337 / 181 / 149 |
| Files using RestTemplate | 865 |
| HttpClient 4 references | 33 |
| Old Kafka error-handler API | 20 |
| Class-level mappings ending in `/` | 30 (24 harmless) |
| **Truly broken trailing-slash mappings** | **6 (4 services)** |
| Services using `server.error.include-stacktrace` | 55 |
| `logback.xml` with janino `<if>` | 1 |
| `bootstrap.yml` | 0 |

---

## Maintaining rewrite.yml — how to verify recipe names

A nonexistent recipe name either fails with "recipe not found" or, worse, **leaves the build green and skips the step silently.** Never guess a name; two ways to verify:

**1. Read the jars (most reliable, offline).** Recipe definitions live in `META-INF/rewrite/*.yml` inside the recipe jars; Java-implemented recipes are the `.class` names:

```bash
unzip -p ~/.m2/repository/org/openrewrite/recipe/rewrite-spring/*/rewrite-spring-*.jar \
  'META-INF/rewrite/spring-boot-40.yml' | sed -n '1,80p'
unzip -l ~/.m2/repository/org/openrewrite/rewrite-maven/*/rewrite-maven-*[0-9].jar \
  | grep -oE 'org/openrewrite/maven/[A-Za-z0-9]+\.class'
```

Every recipe reference in this rewrite.yml was verified against the jars this way. Re-run the check whenever you add a step.

**MergeYaml/DeleteKey behavior, measured on real multi-document application.yml files:** existing blocks are not clobbered, new keys merge in, the output stays valid YAML. Two rules came out of the measurement: (1) target `$.spring` / `$.server` / `$.management` as the key, not a deep root, so the block nests inside the existing tree; (2) **never put comment lines INSIDE the `yaml:` snippet**: MergeYaml glues the comment to the previous line and produces a broken scalar. Comments go above the step, as rewrite.yml's own comments.

**2. Verify by running `rewrite:discover`** with your config and coordinates; unresolvable names fail there, before you touch a service.

**You cannot use a composite partially.** There is no way to exclude one sub-step of a recipe like `UpgradeSpringBoot_4_0`; if a sub-step is unwanted, open the composite and list its children yourself, which is exactly what rewrite.yml does (reasons in its header block).

---

## Primary sources

- Spring Boot 4.0 Migration Guide — <https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-4.0-Migration-Guide>
- Spring Boot 3.0 Migration Guide (the 2.6-to-3.0 step) — <https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-3.0-Migration-Guide>
- Spring Framework 7.0 Release Notes — <https://github.com/spring-projects/spring-framework/wiki/Spring-Framework-7.0-Release-Notes>
- Boot JSON reference (Jackson 3 / jackson2 module) — <https://docs.spring.io/spring-boot/reference/features/json.html>
- "Introducing Jackson 3 support in Spring" — <https://spring.io/blog/2025/10/07/introducing-jackson-3-support-in-spring/>
- Hibernate 7.0 Migration Guide — <https://docs.hibernate.org/orm/7.0/migration-guide/migration-guide.html>
- OpenRewrite recipe catalog — <https://docs.openrewrite.org/recipes>
- `spring-boot-jackson2` artifact — <https://mvnrepository.com/artifact/org.springframework.boot/spring-boot-jackson2/4.0.0>
