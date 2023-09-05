import axios from "axios";

const api = axios.create({
  baseURL: `https://${typeof GetParentResourceName !== "undefined" ? GetParentResourceName() : "feather-inventory"}/`,
});

export default api;
