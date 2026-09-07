package io.clickhouselab.pushclick.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.servers.Server;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.List;

/**
 * OpenAPI metadata for Swagger UI and for exporting a static openapi.json
 * suitable for registering this API with AWS Bedrock AgentCore Gateway.
 *
 * <p>Note on AgentCore Gateway compatibility: Gateway does NOT read
 * {@code securitySchemes} from the OpenAPI document — authentication to the
 * backend is configured separately in the Gateway target (API key, OAuth2,
 * or IAM/SigV4 if the backend sits behind API Gateway/Lambda). So no
 * security scheme is declared here on purpose; do not add one just to
 * "look complete" — Gateway ignores it and some tooling may reject specs
 * whose declared scheme doesn't match how Gateway actually authenticates.
 */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI pushClickOpenAPI() {
        return new OpenAPI()
                .info(new Info()
                        .title("Push/Click Analytics Service")
                        .version("0.1.0")
                        .description("""
                                Records app push-notification sends and user clicks, and exposes \
                                real-time click-through-rate (CTR) statistics per campaign. \
                                Backed by ClickHouse: writes go to append-only event tables \
                                (pushes, clicks), which are continuously and independently \
                                aggregated by two materialized views into hourly per-campaign \
                                counters; the stats endpoint joins those two pre-aggregated \
                                results at query time to compute CTR. \
                                Typical workflow for an agent or client: \
                                (1) call createOrUpdateCustomer once to register a customer, \
                                (2) call recordPushEvent when a push notification is sent to that \
                                customer for a campaign — save the returned sendId, \
                                (3) call recordClickEvent when the customer clicks that push, \
                                passing back the same sendId, customerId, and campaignId, \
                                (4) call getCampaignStats at any time to read up-to-date CTR for \
                                a campaign."""))
                .servers(List.of(new Server()
                        .url("https://api.example.com")
                        .description("Placeholder — replace with this service's real, " +
                                "reachable deployment URL (e.g. an API Gateway or ALB endpoint) " +
                                "before importing this spec into Swagger or registering it as an " +
                                "AWS Bedrock AgentCore Gateway target.")));
    }
}
