package io.geordi.servicemap.application.port.out;

import io.geordi.servicemap.application.ServiceMapQuery;
import io.geordi.servicemap.domain.CandidateTraceBatch;

public interface TraceEvidencePort {

    CandidateTraceBatch findCandidates(ServiceMapQuery query);
}
