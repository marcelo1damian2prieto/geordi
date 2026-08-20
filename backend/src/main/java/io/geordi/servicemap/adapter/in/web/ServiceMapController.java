package io.geordi.servicemap.adapter.in.web;

import io.geordi.servicemap.application.ServiceMapQuery;
import io.geordi.servicemap.application.ServiceMapUseCase;
import io.geordi.servicemap.domain.DependencyEvidence;
import io.geordi.servicemap.domain.ObservedDependency;
import io.geordi.servicemap.domain.ServiceIdentity;
import io.geordi.servicemap.domain.ServiceMapResult;
import io.geordi.servicemap.domain.TimeRange;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@ConditionalOnExpression(
        "${geordi.modules.service-map.enabled:true} && ${geordi.modules.traces.enabled:true}")
@RequestMapping("/api/service-map")
public class ServiceMapController {

    private final ServiceMapUseCase service;

    public ServiceMapController(ServiceMapUseCase service) {
        this.service = service;
    }

    @GetMapping
    public ServiceMapResponse serviceMap(
            @RequestParam String environment,
            @RequestParam String from,
            @RequestParam String to) {
        TimeRange range = new TimeRange(parseOffset(from), parseOffset(to));
        return ServiceMapResponse.from(service.query(new ServiceMapQuery(environment, range)));
    }

    private static java.time.Instant parseOffset(String value) {
        return OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant();
    }

    public record ServiceMapResponse(
            ContextResponse context,
            List<ServiceIdentity> nodes,
            List<EdgeResponse> edges,
            boolean truncated) {

        static ServiceMapResponse from(ServiceMapResult result) {
            return new ServiceMapResponse(
                    new ContextResponse(
                            result.environment(),
                            new RangeResponse(result.range().from().toString(), result.range().to().toString())),
                    result.nodes(),
                    result.edges().stream().map(EdgeResponse::from).toList(),
                    result.truncated());
        }
    }

    public record ContextResponse(String environment, RangeResponse range) {
    }

    public record RangeResponse(String from, String to) {
    }

    public record EdgeResponse(
            ServiceIdentity caller,
            ServiceIdentity callee,
            int evidenceCount,
            List<EvidenceResponse> evidence) {

        static EdgeResponse from(ObservedDependency edge) {
            return new EdgeResponse(
                    edge.caller(),
                    edge.callee(),
                    edge.evidenceCount(),
                    edge.evidence().stream().map(EvidenceResponse::from).toList());
        }
    }

    public record EvidenceResponse(String traceId, String observedAt) {

        static EvidenceResponse from(DependencyEvidence evidence) {
            return new EvidenceResponse(evidence.traceId().value(), evidence.observedAt().toString());
        }
    }
}
