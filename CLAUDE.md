# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Standard build (produces target/UniTime.war)
mvn package -DskipTests

# Clean build
mvn clean package -DskipTests

# Full build with GWT compilation takes several minutes; GWT uses -Xmx1g
# CI uses JDK 17 (Temurin): mvn -B package -Dignore.symbol.file
```

The Maven build: copies Java sources to `target/src/` (filtering `Constants.java` for build number), compiles Java, runs GWT compiler (`org.unitime.timetable.gwt.UniTime`), then packages into a WAR. There is also a legacy Ant build (`build.xml`) that does the same but targets JDK 17 and uses `3rd_party/` for provided-scope JARs.

There is no test suite in the project. `-DskipTests` is used because Maven would otherwise look for a test phase that doesn't exist.

## Deployment

Docker deployment uses files in `../docker-deploy/` (sibling to this repo root):
1. `cp target/UniTime.war ../docker-deploy/web/UniTime.war`
2. From `../docker-deploy/docker/`: `docker-compose down && docker-compose build unitime-web && docker-compose up -d`
3. Verify at http://localhost:8888

The `sync-upstream.sh` script automates: check upstream, archive old WAR + DB dump, merge, build, and optionally deploy with health-check and rollback.

## Architecture

### Request Handling — Two Parallel Stacks

UniTime has two coexisting UI stacks, both running in the same WAR:

1. **Struts 2 + JSP** (legacy pages): Actions in `action/` extend Struts action classes, configured via convention plugin (`struts.convention.package.locators=action`). Each action has a matching JSP in `WebContent/` and a form bean in `form/`. Page layouts use Tiles (`tiles.xml`).

2. **GWT (Google Web Toolkit)** (modern pages): Client-side UI in `gwt/client/`, compiled to JavaScript. Communicates with the server via a custom RPC mechanism — NOT standard GWT-RPC. Instead:
   - Client creates a request object implementing `GwtRpcRequest` (defined in `gwt/shared/`)
   - `GwtRpcServlet` receives it, looks up a server-side handler annotated with `@GwtRpcImplements(RequestClass.class)` (in `server/`)
   - Handlers are Spring components, discovered by component scan

### REST API

API endpoints extend `ApiConnector` and live in `api/connectors/`. They override `doGet`/`doPost`/`doPut`/`doDelete` methods and receive an `ApiHelper` for JSON/XML serialization. Routed through `ApiServlet` which matches URL patterns to connectors.

### Hibernate Entity Model (Three-Layer Pattern)

Each entity has three classes:
- `model/base/Base<Entity>.java` — **auto-generated** from `hibernate.cfg.xml` via `ant create-model`. Contains JPA annotations, fields, getters/setters. Do NOT edit these directly.
- `model/<Entity>.java` — extends `Base<Entity>`, where custom business logic goes. This is the class you edit.
- `model/dao/<Entity>DAO.java` — auto-generated DAO with `findById`, `findAll`, Hibernate session access.

Entity mappings use JPA annotations on `Base*` classes (not `.hbm.xml` files despite some references in config). The `hibernate.cfg.xml` at `JavaSource/hibernate.cfg.xml` lists all mapped classes and defaults to MySQL.

### Configuration System

Application settings are defined as enum constants in `defaults/ApplicationProperty.java` (~4200 lines). Each constant declares its property key, default value, and description. Settings are stored in the `APPLICATION_CONFIG` DB table and accessed via `ApplicationProperties`. Many behaviors (authentication provider, external interfaces, custom class names) are configured this way rather than in XML.

### Security / Permissions

- Authentication: pluggable via Spring Security context files — `securityContext.xml` (built-in), `securityContextLDAP.xml`, `securityContextCAS.xml`, `securityContextOAuth2.xml`. Selected via `unitime.spring.context.security` property.
- Authorization: `security/rights/Right.java` defines all permission constants. Permission logic lives in `security/permissions/` (e.g., `CoursePermissions.java`). Actions check permissions via `SessionContext.checkPermission()`.

### Solver / Optimization Engine

The timetabling solver uses the external `cpsolver` library. Key classes:
- `solver/TimetableDatabaseLoader.java` — loads problem data from Hibernate into solver model
- `solver/TimetableDatabaseSaver.java` — saves solver solution back to DB
- `solver/jgroups/SolverServerImplementation.java` — main class for running solver as a standalone process (see JAR manifest)
- Sub-solvers exist for courses, exams, instructor scheduling, and student sectioning under `solver/` subdirectories

### Data Exchange

XML import/export classes in `dataexchange/` handle bulk data operations (course offerings, rooms, students, curricula, etc.). Each extends `BaseImport` or `BaseExport`. DTDs for XML formats are in `Documentation/Interfaces/`.

### Online Student Sectioning

`onlinesectioning/` is a self-contained subsystem for real-time student course enrollment. It has its own server (`OnlineSectioningServer`), action pattern (`OnlineSectioningAction`), and extensive customization points via `custom/` subpackage interfaces.

## Conventions

- Java source level: 11 (Maven) / 17 (Ant, CI). The project compiles with both.
- Spring component scan base package: `org.unitime` (set in `applicationContext.xml`)
- New GWT server handlers: annotate with `@GwtRpcImplements(YourRequest.class)` — Spring picks them up automatically
- New API endpoints: create a class extending `ApiConnector` in `api/connectors/`
- New Struts actions: follow convention plugin naming in `action/`, they auto-register
- Database: MySQL (default) or Oracle (see `Documentation/Database/` for schema scripts)

## Remotes

- `origin` — https://github.com/imad7654/UniTime.git (fork)
- `upstream` — https://github.com/UniTime/unitime.git (official Apereo project)
