# boot4-migration

A battle-tested recipe for migrating Spring Boot 2.6 / Java 17 microservices to **Spring Boot 4.1 / Java 25 / Spring Cloud 2025.1**.

This is not a tutorial. It is the working toolkit we used to migrate a real fleet of **85 microservices (~41,000 Java files)** at a telco, extracted and generalized for public use. Every known error in the runbook was hit on a real service, diagnosed (with bytecode evidence where behavior was in question), fixed, and written down so that no team ever has to solve it twice.

## What's inside

| File | What it does |
|---|---|
| `SKILL.md` | The runbook. Phased migration process (inventory, freeze, transform, fix loop, verify, deliver, rollback) plus a catalog of **145+ known errors with solutions**, grouped by the phase where they appear: compile, startup, runtime, test, build/CI. Also works as a Claude Code skill: drop it into `.claude/skills/boot4-migration/` and an AI agent can execute the migration end to end. |
| `rewrite.yml` | An OpenRewrite composite recipe that applies the deterministic part of the migration in one command: javax to jakarta, JUnit 4 to Jupiter to JUnit 6, ~740 property key renames, Security 5 to 7, Hibernate 6.2 to 7.1, HttpClient 4 to 5, Boot 4 modular starter moves, Java 25 safe subset, plus dozens of fixes for gaps in the official recipe chain. |
| `scan.sh` | A read-only inventory scanner. Run it at a service repo root and it prints your work list: ~70 signals across 7 groups, including the ones that break silently (contract changes, deploy files, JSON wire format). Non-zero exit when work remains, so it can gate CI. |

## Quick start

```bash
# 0. Inventory: what will this migration touch?
cp scan.sh /path/to/your-service/ && cd /path/to/your-service && bash scan.sh

# 1. Branch from your stable line, then run the recipe (JDK 17 or 21, NOT 25):
cp /path/to/boot4-migration/rewrite.yml .
MAVEN_OPTS=-Xmx4g mvn org.openrewrite.maven:rewrite-maven-plugin:6.46.1:run \
  -Drewrite.configLocation=rewrite.yml \
  -Drewrite.activeRecipes=org.boot4migration.Boot4Java25Upgrade \
  -Drewrite.recipeArtifactCoordinates=org.openrewrite.recipe:rewrite-spring:6.37.1,org.openrewrite.recipe:rewrite-migrate-java:3.42.1,org.openrewrite.recipe:rewrite-testing-frameworks:3.44.0,org.openrewrite.recipe:rewrite-hibernate:2.25.0,org.openrewrite.recipe:rewrite-java-dependencies:1.60.2,org.openrewrite.recipe:rewrite-static-analysis:2.41.1,org.openrewrite.recipe:rewrite-micrometer:0.30.1,org.openrewrite.recipe:rewrite-apache:2.30.0,org.openrewrite.recipe:rewrite-github-actions:3.29.0 \
  -DskipTests

# 2. Commit the recipe output as its own commit (see "Two-commit rule" in SKILL.md).

# 3. Re-run scan.sh: whatever it still flags is manual work.
#    For every error in the compile-and-fix loop, search SKILL.md's
#    "Known errors" catalog FIRST. Most errors are already there, with the fix.

# 4. Verify on JDK 25: mvn clean verify, dependency:tree greps, and a real smoke test.
#    Unit tests are NOT enough; roughly half of the failure classes only appear
#    at startup or on a live request.
```

Three field lessons baked into the command above, learned the hard way:

- Pin recipe versions. `LATEST` does not resolve through most corporate artifact proxies, and unpinned versions mean different services get different transformations.
- Never pass `-U`. Combined with unreachable external repositories it silently breaks dependency resolution, and type-based recipe steps are skipped without any error. The build says SUCCESS and two files changed instead of a hundred.
- Run the recipe with JDK 17 or 21. The plugin compiles the project with its original Boot 2 pom, and Lombok's processor does not run on JDK 25 at that stage.

## The method, in short

1. **Automate the deterministic part.** One composite recipe, pinned versions, identical output on every service.
2. **Two-commit rule.** Commit 1 is pure recipe output; the commit message carries the plugin version, resolved recipe versions and the SHA of `rewrite.yml`, so a reviewer can treat it as machine-generated and reproducible. Commit 2 is human work, and it is small.
3. **Shared library first.** Migrate the library every service depends on, release it, freeze the old line. Every fix that would otherwise be repeated per service lives there.
4. **A ledger of known errors.** Every new error gets solved once and recorded twice: in the runbook for humans, and in `rewrite.yml` when it is deterministic. The recipe gets smarter with every service.
5. **Smoke test as a delivery gate.** Startup, health probes, one real call per controller, a JSON diff against the old version's output, and the OpenAPI path diff. Compilation and unit tests miss entire classes of failures: JSON wire format changes, trailing-slash 404s, sequence naming, timezone storage, dead JDK-8-era libraries.

## What you will need to adapt

The runbook and recipe are generalized, but a few things are placeholders by design:

- **Shared library versions.** Search for `core-util` in `SKILL.md` and the commented example block in `rewrite.yml`; point them at your own shared libraries.
- **Config store.** If your Spring Cloud Config Server uses a JDBC (or vault) backend, property renames must be applied there too; the recipe can only fix files in the repo. The runbook includes the SQL audit pattern and a dual-write strategy so Boot 2 and Boot 4 pods can run side by side.
- **CI specifics.** Jenkinsfile/OpenShift snippets are examples; map them to your pipeline.

## Numbers from the original migration

- 85 services, ~41,000 Java files, 4,022 files with `javax.*` imports, 589 `@Where` annotations, 865 files using RestTemplate.
- Pilot wave: ~3,200 tests green across 8 repos before the fleet rollout started.
- After the toolkit stabilized, a 300-file service took about half a day including a 2,400-test suite; the first service had taken days.

## License

MIT. See `LICENSE`.
